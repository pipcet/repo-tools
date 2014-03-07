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
    my @res;

    while ($path ne ".") {
	push @res, $path;
	$path = dirname($path);
    }

    shift @res;
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

my $version_fh;
open $version_fh, "<$outdir/versions/versions.txt" or die;
while (<$version_fh>) {
    chomp;

    my $path;
    my $head;

    if (($path, $head) = /^(.*): (.*)$/) {
	$version{$path} = $head;
	$rversion{$head} = $path;
    }
}
close $version_fh;

open $version_fh, ">>$outdir/versions/versions.txt";

# see comment at end of file
nsystem("rm $outdir/repo-overlay");

my %dirchanged;
$dirchanged{"."} = 1;
my %oldtype;
my %newtype;
my %status;

my %items;

sub store_item {
    my ($item) = @_;

    $item->{abs} =~ s/\/*$//;
    $item->{rel} =~ s/\/*$//;

    $item->{rel} = substr($item->{abs}, length($item->{repo}));

    my $olditem = $items{$item->{abs}};

    if ($olditem) {
	if (length($olditem->{repo}) > length($item->{repo})) {
	    warn "nested item ". $item->{abs}." in " . $item->{repo} . " and " . $olditem->{repo};
	    return;
	}

	for my $key (keys %$item) {
	    $olditem->{$key} = $item->{$key};
	}
    } else {
	$items{$item->{abs}} = $item;
    }
}

sub previous_commit {
    my ($head) = @_;
    my $last = `git rev-parse '$head~1'`;
    chomp($last);
    if ($last =~ /~1$/) {
	return undef;
    } else {
	return $last;
    }
}

my @repos = repos();
for my $repo (@repos) {
    chdir($pwd);
    chdir($repo);
    my $head = `git rev-parse HEAD`;
    chomp($head);

    if (!defined($rversion{$head}) or
	$head ne $version{$repo}) {
	print $version_fh "$repo: $head\n";
    } elsif ($version{$rversion{$head}} ne $head) {
	die "version mismatch";
    }
    if (1) {
	my $branch = "dirty"; chomp($branch); # XXX
	my $remote = `git config --get branch.$branch.remote`; chomp($remote);
	my $url = `git config --get remote.$remote.url`; chomp($url);
	warn "$repo $branch $remote $url";
	my @heads;
	my @commits;
	for (my $h = $head; defined($h) and $h ne $version{$repo}; $h = previous_commit($h)) {
	    last if $#heads>10;
	    last if $h =~ /\~1$/;
	    push @heads, $h;
	    my $commit = `git log --date=iso $h $h'^'`;
	    if ($url =~ m|^(https?\|git)://(github.com/.*)$|) {
		$commit = "http://$2/commit/$h\n\n" . $commit;
	    }
	    push @commits, $commit;
	}
	my $first = $heads[$#heads];

	if (scalar(@commits)) {
	    my $cmsg = "merged commits in $repo:\n\n";
	    $cmsg .= "see $url\n\n";
	    $cmsg .= join("\n\n", @commits);

	    my $cmsg_fh;
	    open $cmsg_fh, ">>$outdir/versions/cmsg/$first..$head";
	    print $cmsg_fh $cmsg;
	    close $cmsg_fh;
	}
    }

    store_item({abs=>$repo, oldtype=>"dir", repo=>$repo});
    
    my @porc_lines = split(/\0/, `git status -z`);

    my @porc = map { /^(.)(.) (.*)$/; { a => $1, b => $2, path => $3 } } @porc_lines;
    
    for my $p (@porc) {
	my $path = $p->{path};
	my $status = $status{$repo . $path} = $p->{a} . $p->{b};

	if ($status eq "??" and $path =~ /\/$/) {
	    my @extra = split(/\0/, `find $path -name '.git' -prune -o -print0`);
	    map { s/\/*$//; } @extra;

	    for my $extra (@extra) {
		$status{$repo.$extra} = "??";
		store_item({abs=>$repo.$extra, oldtype=>"none", repo=>$repo, status=>"??"});
		for my $pref (prefixes($repo . $extra)) {
		    $dirchanged{$pref} = 1;
		}
	    }
	}

	$path =~ s/\/$//;
	$status{$repo . $path} = $status;
	$oldtype{$repo . $path} = "none" if $status eq "??";
	store_item({abs=>$repo.$path, oldtype=>"none", repo=>$repo, status=>"??"}) if $status eq "??";

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

    next unless scalar(@porc);

    my @lstree_lines = split(/\0/, `git ls-tree -r HEAD -z`);
    my @modes = map { /^(\d\d\d)(\d\d\d) ([^ ]*) ([^ ]*)\t(.*)$/; { mode=> $2, extmode => $1, path => $repo.$5 } } @lstree_lines;

    for my $m (@modes) {
	if ($m->{extmode} eq "120") {
	    store_item({oldtype=>"link", abs=>$m->{path}, repo=>$repo});
	} elsif ($m->{extmode} eq "100") {
	    store_item({oldtype=>"file", abs=>$m->{path}, repo=>$repo});
	} else {
	    die "unknown mode";
	}

	for my $pref (prefixes($m->{path})) {
	    last if length($pref) < length($repo);
	    store_item({oldtype=>"dir", abs=>$pref, repo=>$repo});
	}
    }
}

chdir($pwd);
for my $item (values %items) {
    if (-l $item->{abs}) {
	$item->{newtype} = "link";
    } elsif (!-e $item->{abs}) {
	$item->{newtype} = "none";
    } elsif (-d $item->{abs}) {
	$item->{newtype} = "dir";
    } elsif (-f $item->{abs}) {
	$item->{newtype} = "file";
    } else {
	die;
    }

    $item->{oldtype} = $item->{newtype} unless defined($item->{oldtype});
}

chdir($outdir);
for my $item (values %items) {
    my $abs = $item->{abs};
    my $rel = $item->{rel};
    my $type = $item->{newtype};
    my $oldtype = $item->{oldtype};
    my $repo = $item->{repo};

    if ($oldtype eq "dir") {
	my $dir = $abs;

	die if $dir eq ".";
	my $dirname = $dir;
	while(!$dirchanged{$dirname}) {
	    ($dir, $dirname) = ($dirname, dirname($dirname));
	}

	if (!$dirchanged{$dir}) {
	    if (! (-e "import/$dir" || -l "import/$dir")) {
		symlink_relative("$outdir/repo-overlay/$dir", "import/$dir") or die;
	    }
	}
    }
    if ($type eq "dir") {
	my $dir = $abs;

	die if $dir eq ".";
	my $dirname = $dir;
	while(!$dirchanged{$dirname}) {
	    ($dir, $dirname) = ($dirname, dirname($dirname));
	}

	if (!$dirchanged{$dir}) {
	    if (! (-e "export/$dir" || -l "export/$dir")) {
		symlink_relative("$outdir/repo-overlay/$dir", "export/$dir") or die;
	    }
	}
    }
    if ($oldtype eq "file") {
	my $file = $rel;

	my $dirname = dirname($file);
	my $fullpath = $repo . $dirname;
	$fullpath =~ s/\/\.$//;
	next unless $dirchanged{$fullpath};
	my $status = $status{$repo . $file};
	if (!defined($status)) {
	    symlink_relative("$outdir/repo-overlay/$repo$file", "import/$repo$file") or die;
	} elsif ($status eq "??") {
	} elsif ($status eq " M") {
	    cat_file($repo, $file, "import/$repo$file");
	} elsif ($status eq " D") {
	    cat_file($repo, $file, "import/$repo$file");
	} else {
	    die "unknown status $status for $repo$file";
	}
    }
    if ($type eq "file") {
	my $file = $rel;

	my $dirname = dirname($file);
	my $fullpath = $repo . $dirname;
	$fullpath =~ s/\/\.$//;
	next unless $dirchanged{$fullpath};
	my $status = $status{$repo . $file};
	if (!defined($status)) {
	    symlink_relative("$outdir/repo-overlay/$repo$file", "export/$repo$file") or die;
	} elsif ($status eq "??") {
	    copy_or_hardlink("$pwd/$repo$file", "export/$repo$file") or die;
	} elsif ($status eq " M") {
	    copy_or_hardlink("$pwd/$repo$file", "export/$repo$file") or die;
	} elsif ($status eq " D") {
	} else {
	    die "unknown status $status for $repo$file";
	}
    }
    if ($oldtype eq "link") {
	my $file = $rel;
	warn "link $file $repo $abs";
	my $dirname = dirname($file);
	my $fullpath = $repo . $dirname;
	$fullpath =~ s/\/\.$//;
	next unless $dirchanged{$fullpath};
	my $status = $status{$repo . $file};
	if (!defined($status)) {
	    symlink_absolute(`(cd $pwd/$repo; git cat-file blob HEAD:'$file')`, "import/$repo$file") or die;
	} elsif ($status eq "??") {
	} else {
	    die "unknown status $status for $repo$file";
	}
    }
    if ($type eq "link") {
	my $file = $rel;
	warn "link $file";
	my $dirname = dirname($file);
	my $fullpath = $repo . $dirname;
	$fullpath =~ s/\/\.$//;
	next unless $dirchanged{$fullpath};
	my $status = $status{$repo . $file};
	if (!defined($status)) {
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
