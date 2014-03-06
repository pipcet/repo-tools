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
sub copy_or_hardlink {
    my ($src, $dst) = @_;

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

chdir($indir) or die;

my $pwd = `pwd`;
chomp($pwd);
nsystem("rm -rf $outdir/import/*");
nsystem("rm -rf $outdir/export/*");
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

my @repos = repos();
for my $repo (@repos) {
    my $noslash = $repo;
    $noslash =~ s/\/$//;
    $dirchanged{$noslash} = 1;
    $dirchanged{dirname($repo)} = 1;
}
for my $repo (@repos) {
    warn "repo $repo";
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
    
    print "repo $repo head $head " . scalar(@porc) . "\n";

    my %status;
    for my $p (@porc) {
	my $path = $p->{path};
	my $status = $status{$repo . $path} = $p->{a} . $p->{b};

	if ($status eq "??" and $path =~ /\/$/) {
	    my @extra = split(/\0/, `find $path -name '.git' -prune -o -print0`);
	    map { s/\/*$//; } @extra;

	    for my $extra (@extra) {
		$status{$repo . $extra} = "??";
		for my $pref (prefixes($repo . $extra)) {
		    warn "dirchanged $pref";
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

    chdir($pwd);
    my @dirs = split(/\0/, `find '$repo' -name '.git' -prune -o -type d -print0`);
    chdir($repo);

    my @files = split(/\0/, `find -name '.git' -prune -o -type f -print0`);
    my @links = split(/\0/, `find -name '.git' -prune -o -type l -print0`);
    my @other = split(/\0/, `find -name '.git' -prune -o -not '(' -type d -o -type f -o -type l ')' -print0`);

    die join(", ", @other) if scalar(@other);

    map { s/^\.\///; } @files;
    map { s/^\.\///; s/\/$//; } @dirs;
    map { s/^\.\///; } @links;
    
    @files = grep {$_ ne ""} @files;
    @dirs = grep {$_ ne ""} @dirs;
    @links = grep {$_ ne ""} @links;

    map { warn "spaces in $_" if $_ =~ / /; } (@files,@dirs,@links);
    map { die "single quote in $_" if $_ =~ /\'/; } (@files,@dirs,@links);
    
    chdir($outdir);
    
    for my $dir (@dirs) {
	my $status = $status{$dir};
	die if $dir eq ".";
	for (my $dirname = $dir; $dirname ne "."; ($dir, $dirname) = ($dirname, dirname($dirname))) {
	    if ($dirchanged{$dirname}) {
		if ($status{$dirname} ne "??" and ! -d "import/$dirname") {
		    nsystem("mkdir -p '$outdir/import/$dirname'") or die;
		}
		if ($status{$dirname} ne " D" and ! -d "export/$dirname") {
		    nsystem("mkdir -p '$outdir/export/$dirname'") or die;
		}

		if ($status{$dirname} ne "??" and ! (-e "import/$dir" || -l "import/$dir")) {
		    nsystem("ln -nvsr '$outdir/repo-overlay/$dir' import/'$dir'") or die;
		}
		if ($status{$dirname} ne " D" and ! (-e "export/$dir" || -l "export/$dir")) {
		    nsystem("ln -nvsr '$outdir/repo-overlay/$dir' export/'$dir'") or die;
		}
		last;
	    }
	}
    }

    for my $file (@files) {
	#warn "file $file";
	my $dirname = dirname($file);
	my $fullpath = $repo . $dirname;
	$fullpath =~ s/\/\.$//;
	next unless $dirchanged{$fullpath};
	my $status = $status{$repo . $file};
	if (!defined($status)) {
	    nsystem("ln -nsrv '$outdir/repo-overlay/$repo$file' import/'$repo$file'") or die;
	    nsystem("ln -nsrv '$outdir/repo-overlay/$repo$file' export/'$repo$file'") or die;
	} elsif ($status eq "??") {
	    copy_or_hardlink("$pwd/$repo$file", "export/$repo$file") or die;
	} elsif ($status eq " M") {
	    nsystem("(cd $pwd/$repo; git cat-file blob HEAD:'$file') > import/'$repo$file'") or die;
	    copy_or_hardlink("$pwd/$repo$file", "export/$repo$file") or die;
	} elsif ($status eq " D") {
	    nsystem("(cd $pwd/$repo; git cat-file blob HEAD:'$file') > import/'$repo$file'") or die;
	} else {
	    die "unknown status $status for $repo$file";
	}
    }

    for my $file (@links) {
	warn "link $file";
	my $dirname = dirname($file);
	my $fullpath = $repo . $dirname;
	$fullpath =~ s/\/\.$//;
	next unless $dirchanged{$fullpath};
	my $status = $status{$repo . $file};
	if (!defined($status)) {
	    nsystem("ln -sv `(cd $pwd/$repo; git cat-file blob HEAD:'$file')` import/'$repo$file'") or die;
	    copy_or_hardlink("$pwd/$repo$file", "export/$repo$file") or die;
	} elsif ($status eq "??") {
	    copy_or_hardlink("$pwd/$repo$file", "export/$repo$file") or die;
	} else {
	    die "unknown status $status for $repo$file";
	}
    }
    
    chdir($pwd);
}

copy_or_hardlink("$pwd/README.md", "$outdir/import/") or die;
copy_or_hardlink("$pwd/README.md", "$outdir/export/") or die;

# this must come after all symbolic links have been created, so ln
# doesn't get confused about which relative path to use.
nsystem("ln -sv $pwd $outdir/repo-overlay");

# useful commands:
#  repo-overlay.pl -- sync repository to export/ import/
#  diff -ur repo-overlay/ export/|(cd repo-overlay; patch -p1) -- sync export/ to repository (doesn't handle new/deleted files)
