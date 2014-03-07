#!/usr/bin/perl
use strict;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Getopt::Long qw(:config auto_version auto_help);

sub repos {
    my @repos = split(/\0/, `find  -name '.git' -print0 -prune -o -name '.repo' -prune -o -path './out' -prune`);
#pop(@repos);
    map { chomp; s/\.git$//; } @repos;
    map { s/^\.\///; } @repos;

    unshift @repos, ".repo/repo/";
    unshift @repos, ".repo/manifests/";

    # we currently fail horribly if there are actual changes in nested
    # git repositories. On the android repo, that affects only
    # chromium_org/, which I'm not touching, for now.
    my %have;
    for my $repo (@repos) {
	$have{$repo} = 1;
    }

REPO:
    for my $repo (@repos) {
	for my $prefix (prefixes($repo)) {
	    warn "$repo nested in $prefix" if ($have{$prefix."/"});
	    delete($have{$repo}) if ($have{$prefix."/"});
	}
    }
    
    return grep { $have{$_} } @repos;
}

# all ancestor directories of a path
sub prefixes {
    my ($path) = @_;
    my @components = split(/\//, $path);
    my @res;

    while ($path ne ".") {
	push @res, $path;
	$path = dirname($path);
    }

    return @res;
}

# like system(), but not the return value and echo command
sub nsystem {
    my ($cmd) = @_;

    warn "running $cmd\n";

    return !system($cmd);
}

my $do_hardlink;
sub mkdirp {
    my ($dir) = @_;

    if (-d $dir) {
	return 1;
    } else {
	return nsystem("mkdir -p '$dir'");
    }
}

sub symlink_relative {
    my ($src, $dst) = @_;

    mkdirp(dirname($dst)) or die;

    nsystem("ln -nsrv '$src' '$dst'") or die;
}

sub symlink_absolute {
    my ($src, $dst) = @_;

    mkdirp(dirname($dst)) or die;

    nsystem("ln -sv '$src' '$dst'") or die;
}

sub copy_or_hardlink {
    my ($src, $dst) = @_;

    mkdirp(dirname($dst)) or die;

    my $hl = $do_hardlink ? "al" : "a";

    return nsystem("cp -v$hl '$src' '$dst'") or die;
}


my $outdir;
my $indir = ".";

GetOptions(
    "hardlink!" => \$do_hardlink,
    "out=s" => \$outdir,
    "in=s" => \$indir,
    );

$outdir =~ s/\/*$//;
$indir =~ s/\/*$//;

chdir($indir) or die;

my $pwd = `pwd`;
chomp($pwd);


sub cat_file {
    my ($repo, $file, $dst) = @_;

    mkdirp(dirname($dst)) or die;

    nsystem("(cd $pwd/$repo; git cat-file blob HEAD:'$file') > $dst") or die;
}

nsystem("rm -rf $outdir/import/*");
nsystem("rm -rf $outdir/export/*");
nsystem("rm -rf $outdir/import/.repo");
nsystem("rm -rf $outdir/export/.repo");
nsystem("mkdir -p $outdir/import $outdir/export $outdir/versions") or die;

my %version;
my %rversion;

my $fh;
open $fh, "<$outdir/versions/versions.txt" or die;
while (<$fh>) {
    chomp;

    my $path;
    my $head;

    if (($path, $head) = /^(.*): (.*)$/) {
	$version{$path} = $head;
	$rversion{$head} = $path;
    }
}
close $fh;

open $fh, ">>$outdir/versions/versions.txt";

# see comment at end of file
nsystem("rm $outdir/repo-overlay");

my %dirchanged;
$dirchanged{"."} = 1;
my %status;

my @repos = repos();
for my $repo (@repos) {
    chdir($pwd);
    chdir($repo);
    my $head = `git rev-parse HEAD`;
    chomp($head);

    if (!defined($rversion{$head})) {
	print $fh "$repo: $head\n";
    } elsif ($version{$rversion{$head}} ne $head) {
	die "version mismatch";
    }
    
    my @porc_lines = split(/\0/, `git status -z`);

    my @porc = map { /^(.)(.) (.*)$/; { a => $1, b => $2, path => $3 } } @porc_lines;
    
    for my $p (@porc) {
	my $path = $p->{path};
	my $status = $status{$repo . $path} = $p->{a} . $p->{b};

	if ($status eq "??" and $path =~ /\/$/) {
	    my @extra = split(/\0/, `find $path -name '.git' -prune -o -print0`);
	    map { s/\/*$//; } @extra;

	    for my $extra (@extra) {
		$status{$repo . $extra} = "??";
		for my $pref (prefixes($repo . $extra)) {
		    $dirchanged{$pref} = 1;
		}
	    }
	}

	$path =~ s/\/$//;
	$status{$repo . $path} = $status;

	if ($status eq "??" or
	    $status eq " M" or
	    $status eq " D") {
	    for my $pref (prefixes($repo . $path)) {
		$dirchanged{$pref} = 1;
	    }
	} else {
	    die "unknown status $status in repo $repo, path " . $p->{path};
	}
    }
}

my %items;
sub store_item {
    my ($item) = @_;

    my $olditem = $items{$item->{abs}};

    if ($olditem) {
	if (length($olditem->{repo}) > length($item->{repo})) {
	    warn "nested item in " . $item->{repo} . " and " . $olditem->{repo};
	    return;
	}
    }

    $items{$item->{abs}} = $item;
}

for my $repo (@repos) {
    my @items;

    chdir($pwd);
    my @dirs = split(/\0/, `find '$repo' -name '.git' -prune -o -type d -print0`);
    my @files = split(/\0/, `find '$repo' -name '.git' -prune -o -type f -print0`);
    my @links = split(/\0/, `find '$repo' -name '.git' -prune -o -type l -print0`);
    my @other = split(/\0/, `find '$repo' -name '.git' -prune -o -not '(' -type d -o -type f -o -type l ')' -print0`);

    chdir($repo);

    die join(", ", @other) if scalar(@other);

    map { s/^\.\///; } @files;
    map { s/^\.\///; s/\/$//; } @dirs;
    map { s/^\.\///; } @links;
    
    @files = grep {$_ ne ""} @files;
    @dirs = grep {$_ ne ""} @dirs;
    @links = grep {$_ ne ""} @links;

    map { warn "spaces in $_" if $_ =~ / /; } (@files,@dirs,@links);
    map { die "single quote in $_" if $_ =~ /\'/; } (@files,@dirs,@links);
    
    for my $file (@dirs) {
	my $abspath = $file;
	# potentially empty
	my $relpath = substr($abspath, length($repo));
	my $type = "dir";

	store_item({ abs => $abspath, rel => $relpath, repo => $repo, type => $type });
    }

    for my $file (@files) {
	my $abspath = $file;
	die unless substr($abspath, 0, length($repo)) eq $repo;
	my $relpath = substr($abspath, length($repo));
	my $type = "file";

	store_item({ abs => $abspath, rel => $relpath, repo => $repo, type => $type });
    }

    for my $file (@links) {
	my $abspath = $file;
	die unless substr($abspath, 0, length($repo)) eq $repo;
	my $relpath = substr($abspath, length($repo));
	my $type = "link";

	store_item({ abs => $abspath, rel => $relpath, repo => $repo, type => $type });
    }

    chdir($outdir);
}

chdir($outdir);

for my $item (values %items) {
    my $abs = $item->{abs};
    my $rel = $item->{rel};
    my $type = $item->{type};
    my $repo = $item->{repo};

    if ($type eq "dir") {
	my $dir = $abs;

	my $status = $status{$dir};
	die if $dir eq ".";
	my $dirname = $dir;
	while(!$dirchanged{$dirname}) {
	    ($dir, $dirname) = ($dirname, dirname($dirname));
	}

	if (!$dirchanged{$dir}) {
	    if ($status{$dirname} ne "??" and ! (-e "import/$dir" || -l "import/$dir")) {
		symlink_relative("$outdir/repo-overlay/$dir", "import/$dir") or die;
	    }
	    if ($status{$dirname} ne " D" and ! (-e "export/$dir" || -l "export/$dir")) {
		symlink_relative("$outdir/repo-overlay/$dir", "export/$dir") or die;
	    }
	}
    } elsif ($type eq "file") {
	my $file = $rel;

	my $dirname = dirname($file);
	my $fullpath = $repo . $dirname;
	$fullpath =~ s/\/\.$//;
	next unless $dirchanged{$fullpath};
	my $status = $status{$repo . $file};
	if (!defined($status)) {
	    symlink_relative("$outdir/repo-overlay/$repo$file", "import/$repo$file") or die;
	    symlink_relative("$outdir/repo-overlay/$repo$file", "export/$repo$file") or die;
	} elsif ($status eq "??") {
	    copy_or_hardlink("$pwd/$repo$file", "export/$repo$file") or die;
	} elsif ($status eq " M") {
	    cat_file($repo, $file, "import/$repo$file");
	    copy_or_hardlink("$pwd/$repo$file", "export/$repo$file") or die;
	} elsif ($status eq " D") {
	    cat_file($repo, $file, "import/$repo$file");
	} else {
	    die "unknown status $status for $repo$file";
	}
    } elsif ($type eq "link") {
	my $file = $rel;
	warn "link $file";
	my $dirname = dirname($file);
	my $fullpath = $repo . $dirname;
	$fullpath =~ s/\/\.$//;
	next unless $dirchanged{$fullpath};
	my $status = $status{$repo . $file};
	if (!defined($status)) {
	    symlink_absolute(`(cd $pwd/$repo; git cat-file blob HEAD:'$file')`, "import/$repo$file") or die;
	    copy_or_hardlink("$pwd/$repo$file", "export/$repo$file") or die;
	} elsif ($status eq "??") {
	    copy_or_hardlink("$pwd/$repo$file", "export/$repo$file") or die;
	} else {
	    die "unknown status $status for $repo$file";
	}
    }
}

chdir($pwd);

copy_or_hardlink("$pwd/README.md", "$outdir/import/") or die;
copy_or_hardlink("$pwd/README.md", "$outdir/export/") or die;

# this must come after all symbolic links have been created, so ln
# doesn't get confused about which relative path to use.
nsystem("ln -sv $pwd $outdir/repo-overlay");

# useful commands:
#  repo-overlay.pl -- sync repository to export/ import/
#  diff -ur repo-overlay/ export/|(cd repo-overlay; patch -p1) -- sync export/ to repository (doesn't handle new/deleted files)
#  diff -urNx .git -x .repo -x out -x out-old repo-overlay/ export/|(cd repo-overlay; patch -p1)
