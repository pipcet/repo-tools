#!/usr/bin/perl
use strict;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Getopt::Long qw(:config auto_version auto_help);
use File::PathConvert qw(abs2rel);
use File::Copy::Recursive qw(fcopy);
sub repos {
    my @repos = split(/\0/, `find  -name '.git' -print0 -prune -o -name '.repo' -prune -o -path './out' -prune`);
#pop(@repos);
    map { chomp; s/\.git$//; } @repos;
    map { s/^\.\///; } @repos;

    unshift @repos, ".repo/repo/";
    unshift @repos, ".repo/manifests/";

    return @repos;
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

    return !system($cmd);
}

my $do_hardlink;
sub mkdirp {
    my ($dir) = @_;

    make_path($dir);

    return 1;
}

sub symlink_relative {
    my ($src, $dst) = @_;
    my $relsrc = abs2rel($src, dirname($dst));

    mkdirp(dirname($dst)) or die;

    symlink($relsrc, $dst) or die;
}

sub symlink_absolute {
    my ($src, $dst) = @_;

    mkdirp(dirname($dst)) or die;

    symlink($src, $dst) or die;
}

sub copy_or_hardlink {
    my ($src, $dst) = @_;

    fcopy($src, $dst);

    return 1;
}

my $do_new_versions;
my $do_new_symlinks;
my $do_print_range;

my $apply;
my $apply_repo;
my $apply_success;

my $outdir;
my $indir = ".";

my $branch = '@{1.month.ago}';
my $commit_message_file;

my $commit_commitdate;
my $commit_committer;
my $commit_authordate;
my $commit_author;

GetOptions(
    "hardlink!" => \$do_hardlink,
    "out=s" => \$outdir,
    "in=s" => \$indir,
    "branch=s" => \$branch,
    "print-range!" => \$do_print_range,
    "new-versions!" => \$do_new_versions,
    "new-symlinks!" => \$do_new_symlinks,
    "apply=s" => \$apply,
    "apply-repo=s" => \$apply_repo,
    "commit-message-file=s" => \$commit_message_file,
    "commit-authordate=s" => \$commit_authordate,
    "commit-author=s" => \$commit_author,
    "commit-commitdate=s" => \$commit_commitdate,
    "commit-committer=s" => \$commit_committer,
    ) or die;

$apply_repo =~ s/\/*$/\//;
$apply_repo =~ s/^\.\///;

$outdir =~ s/\/*$//;
$indir =~ s/\/*$//;

chdir($indir) or die;

my $pwd = `pwd`;
chomp($pwd);

sub cat_file {
    my ($repo, $branch, $file, $dst) = @_;

    mkdirp(dirname($dst)) or die;

    if ($branch ne "") {
	nsystem("(cd $pwd/$repo; git cat-file blob '$branch':'$file') > $dst") or die;
    } else {
	nsystem("cat $pwd/$repo/$file > $dst") or die;
    }
}

my %items;

sub store_item {
    my ($item) = @_;

    $item->{abs} =~ s/\/*$//;
    $item->{rel} =~ s/\/*$//;

    $item->{rel} = substr($item->{abs}, length($item->{repo}));

    my $olditem = $items{$item->{abs}};

    if ($olditem) {
	my $repo = $item->{repo};
	if (length($olditem->{repo}) > length($item->{repo})) {
	    $repo = $olditem->{repo};
	}

	for my $key (keys %$item) {
	    $olditem->{$key} = $item->{$key};
	}
	$olditem->{repo} = $repo;
	$olditem->{rel} = substr($olditem->{abs}, length($repo));
    } else {
	$items{$item->{abs}} = $item;
    }
}

# see comment at end of file
nsystem("rm $outdir/repo-overlay 2>/dev/null"); #XXX use as lock

nsystem("mkdir -p $outdir/import $outdir/export $outdir/versions") or die;

if ($do_new_versions) {
    nsystem("rm $outdir/versions/versions.txt; touch $outdir/versions/versions.txt");
}

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

sub revparse {
    my ($head) = @_;
    my $last = `git rev-parse '$head' 2>/dev/null`;
    chomp($last);
    if ($last =~ /~1$/ or
	length($last) < 10) {
	return undef;
    } else {
	return $last;
    }
}

if ($do_print_range and defined($apply_repo)) {
    chdir($pwd);
    chdir($apply_repo);
    print "$version{$apply_repo}.." . revparse("HEAD") . "\n";

    exit(0);
}

if (defined($apply) and defined($apply_repo)) {
    die if $apply eq "";

    my $repo = $apply_repo;
    chdir($repo);
    # XXX octopus merges are broken. How do I find out how many parents a commit has?
    if (revparse($apply . "^") eq $version{$repo}) {
	warn "should be able to apply commit $apply to $apply_repo.";
    } elsif (revparse($apply . "^2") eq $version{$repo}) {
	warn "should be able to apply commit $apply to $apply_repo.";
    } elsif (revparse($apply . "^3") eq $version{$repo}) {
	warn "should be able to apply commit $apply to $apply_repo.";
    } else {
	my $msg = "cannot apply commit $apply to $repo @" . $version{$repo} . " != " . revparse($apply . "^") . "\n";
	if (nsystem("git merge-base --is-ancestor $apply $version{$repo}")) {
	    exit(0);
	}
	if (nsystem("git merge-base --is-ancestor $version{$repo} $apply")) {
	    $msg .= "missing link for $repo";
	}

	$msg .= " repo ancestors:\n";
	$msg .= "".revparse($version{$repo}."")."\n";
	$msg .= "".revparse($version{$repo}."~1")."\n";
	$msg .= "".revparse($version{$repo}."~2")."\n";
	$msg .= "".revparse($version{$repo}."~3")."\n";
	$msg .= "".revparse($version{$repo}."~4")."\n";
	$msg .= " commit ancestors:\n";
	$msg .= "".revparse($apply."")."\n";
	$msg .= "".revparse($apply."~1")."\n";
	$msg .= "".revparse($apply."~2")."\n";
	$msg .= "".revparse($apply."~3")."\n";
	$msg .= "".revparse($apply."~4")."\n";

	$msg .= "\ngit log:\n";
	$msg .= `git log -1`;
	$msg .= "\ncommit file:\n";
	$msg .= `head -8 $commit_message_file`;

	$msg .= "\n\n\n";

	die($msg);
    }
    chdir($pwd);
}

unless ($do_new_symlinks) {
    chdir("$outdir/import");
    my @dirs = split(/\0/, `find -name .git -prune -o -type d -print0`);

    for my $dir (@dirs) {
	$dir =~ s/^\.\///;
	$dir =~ s/\/*$//;
	store_item({abs=>$dir, changed=>1});
    }

    my @files = split(/\0/, `find -name .git -prune -o -type f -print0`);

    for my $file (@files) {
	$file =~ s/^\.\///;
	$file =~ s/\/*$//;
	store_item({abs=>$file, changed=>1});
    }

    chdir($pwd);
}

if ($do_new_symlinks or !defined($apply_repo)) {
    nsystem("rm -rf $outdir/import/*");
    nsystem("rm -rf $outdir/export/*");
    nsystem("rm -rf $outdir/import/.repo");
    nsystem("rm -rf $outdir/export/.repo");
} else {
    # rm -rf dangling-symlink/ doesn't delete anything. Learn
    # something new every day.
    nsystem("rm -rf $outdir/import/" . ($apply_repo =~ s/\/$//r));
    nsystem("rm -rf $outdir/export/" . ($apply_repo =~ s/\/$//r));
}

my @repos;
if (defined($apply) and defined($apply_repo) and
    !$do_new_symlinks and !$do_new_versions) {
    @repos = ($apply_repo =~ s/\/*$/\//r);
} else {
    @repos = repos();
}
my %repos;
store_item({abs=>"", changed=>1});
store_item({abs=>".", changed=>1});
for my $repo (@repos) {
    $repos{$repo} = { repo=>$repo };
    chdir($pwd);
    chdir($repo);
    my $head;
    if ($do_new_versions) {
	$head = revparse($branch) // revparse("HEAD");
    } else {
	$head = $version{$repo} // revparse($branch) // revparse("HEAD");
    }

    my $oldhead = $head;

    if (defined($apply)) {
	if (revparse($apply . "^") eq $head or
	    revparse($apply . "^2") eq $head or
	    revparse($apply . "^3") eq $head) {
	    $head = $apply;
	    warn "successfully applied $apply to $repo";
	    $apply_success = 1;
	}
    }
    $repos{$repo}{head} = $head;

    if (!defined($rversion{$head}) or
	$head ne $version{$repo}) {
    } elsif ($version{$rversion{$head}} ne $head) {
	die "version mismatch";
    }

    store_item({abs=>($repo =~ s/\/*$//r), oldtype=>"dir", repo=>$repo});
    for my $pref (prefixes($repo)) {
	store_item({abs=>$pref, oldtype=>"dir"});
    }

    my %diffstat;
    if ($oldhead eq $head) {
	%diffstat = reverse split(/\0/, `git diff $head --name-status -z`);
    } else {
	%diffstat = reverse split(/\0/, `git diff $oldhead..$head --name-status -z`);
    }

    for my $path (keys %diffstat) {
	my $stat = $diffstat{$path};

	if ($stat eq "M") {
	    store_item({abs=>$repo.$path, status=>" M", changed=>1});
	    for my $pref (prefixes($repo . $path)) {
		store_item({abs=>$pref, changed=>1});
	    }
	} elsif ($stat eq "A") {
	    store_item({abs=>$repo.$path, oldtype=>"none", repo=>$repo, status=>"??", changed=>1});
	    for my $pref (prefixes($repo . $path)) {
		store_item({abs=>$pref, changed=>1});
	    }
	} elsif ($stat eq "D") {
	    store_item({abs=>$repo.$path, status=>" D", changed=>1});
	    for my $pref (prefixes($repo . $path)) {
		store_item({abs=>$pref, changed=>1});
	    }
	} else {
	    die "$stat $path";
	}
    }

    if (!$items{$repo =~ s/\/$//r}{changed}) {
	store_item({oldtype=>"dir", abs=>($repo =~ s/\/$//r), repo=>$repo});

	next;
    }

    # git ls-tree shows both files and directories, but doesn't
    # recurse. git ls-tree -r recurses, but doesn't show
    # directories. git ls-tree -dr recurses, but only shows
    # directories. We want everything.
    my @lstree_lines = (split(/\0/, `git ls-tree -r '$head' -z`),
			split(/\0/, `git ls-tree -d -r '$head' -z`));
    my @modes = map { /^(\d\d\d)(\d\d\d) ([^ ]*) ([^ ]*)\t(.*)$/; { mode=> $2, extmode => $1, path => $repo.$5 } } @lstree_lines;

    for my $m (@modes) {
	next unless $items{dirname($m->{path})} and $items{dirname($m->{path})}{changed};

	if ($m->{extmode} eq "120") {
	    store_item({oldtype=>"link", abs=>$m->{path}, repo=>$repo});
	} elsif ($m->{extmode} eq "100") {
	    store_item({oldtype=>"file", abs=>$m->{path}, repo=>$repo});
	} elsif ($m->{extmode} eq "040") {
	    store_item({oldtype=>"dir", abs=>$m->{path}, repo=>$repo});
	} else {
	    die "unknown mode";
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
    my $repo = $item->{repo};
    next unless $repos{$repo};
    my $abs = $item->{abs};
    next if $abs eq "" or $abs eq ".";
    next unless $items{dirname($abs)}{changed};
    my $rel = $item->{rel};
    my $type = $item->{newtype};
    my $oldtype = $item->{oldtype};
    my $head = $repos{$repo}{head};

    if ($oldtype eq "dir") {
	my $dir = $abs;

	die if $dir eq ".";
	my $dirname = $dir;
	while(!$items{$dirname}{changed}) {
	    ($dir, $dirname) = ($dirname, dirname($dirname));
	}

	if (!$items{$dir}{changed}) {
	    if (! (-e "import/$dir" || -l "import/$dir")) {
		symlink_relative("$outdir/repo-overlay/$dir", "import/$dir") or die;
	    }
	}
    }
    if ($type eq "dir") {
	my $dir = $abs;

	die if $dir eq ".";
	my $dirname = $dir;
	while(!$items{$dirname}{changed}) {
	    ($dir, $dirname) = ($dirname, dirname($dirname));
	}

	if (!$items{$dir}{changed}) {
	    if (! (-e "export/$dir" || -l "export/$dir")) {
		symlink_relative("$outdir/repo-overlay/$dir", "export/$dir") or die;
	    }
	}
    }
    if ($oldtype eq "file") {
	my $file = $rel;

	if ($item->{changed}) {
	    cat_file($repo, $head, $file, "import/$repo$file");
	} else {
	    symlink_relative("$outdir/repo-overlay/$repo$file", "import/$repo$file") or die;
	}
    }
    if ($type eq "file") {
	my $file = $rel;

	if ($item->{changed}) {
	    copy_or_hardlink("$pwd/$repo$file", "export/$repo$file") or die;
	} else {
	    symlink_relative("$outdir/repo-overlay/$repo$file", "export/$repo$file") or die;
	}
    }
    if ($oldtype eq "link") {
	my $file = $rel;

	symlink_absolute(`(cd $pwd/$repo; git cat-file blob '$head':'$file')`, "import/$repo$file") or die;
    }
    if ($type eq "link") {
	my $file = $rel;

	copy_or_hardlink("$pwd/$repo$file", "export/$repo$file") or die;
    }
}

chdir($pwd);

if ($apply_success or $do_new_versions) {
    open $version_fh, ">>$outdir/versions/versions.txt";
    for my $repo (@repos) {
	print $version_fh "$repo: $apply\n";
    }
    close $version_fh;
}

copy_or_hardlink("$pwd/README.md", "$outdir/import/") or die;
copy_or_hardlink("$pwd/README.md", "$outdir/export/") or die;
copy_or_hardlink("$pwd/Makefile", "$outdir/import/") or die;
copy_or_hardlink("$pwd/Makefile", "$outdir/export/") or die;
copy_or_hardlink("$outdir/versions/versions.txt", "$outdir/import/") or die;

# this must come after all symbolic links have been created, so ln
# doesn't get confused about which relative path to use.
nsystem("ln -s $pwd $outdir/repo-overlay");

if (defined($commit_message_file)) {
    chdir("$outdir/import");
    nsystem("git add --all; git commit --allow-empty -F $commit_message_file " .
	    (defined($commit_authordate) ? "--date '$commit_authordate' " : "") .
	    (defined($commit_author) ? "--author '$commit_author' " : ""));
}

# useful commands:
#  repo-overlay.pl -- sync repository to export/ import/
#  diff -ur repo-overlay/ export/|(cd repo-overlay; patch -p1) -- sync export/ to repository (doesn't handle new/deleted files)
#  diff -urNx .git -x .repo -x out -x out-old repo-overlay/ export/|(cd repo-overlay; patch -p1)

# perl ~/repo-tools/repo-overlay.pl --new-symlinks --new-versions --out=/home/pip/tmp-repo-overlay
# perl ~/repo-tools/repo-log.pl --just-shas|tac|while read; do echo $REPLY; sh -c "perl ~/repo-tools/repo-overlay.pl $REPLY --out=/home/pip/tmp-repo-overlay" && (cd ~/tmp-repo-overlay/import; git add --all .; git commit --allow-empty -m "$REPLY"); done
# perl ~/repo-tools/repo-log.pl --just-shas|tac|while read; do echo $REPLY; sh -c "perl ~/repo-tools/repo-overlay.pl $REPLY --out=/home/pip/tmp-repo-overlay"; done

exit(0);
