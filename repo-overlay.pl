#!/usr/bin/perl
use strict;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Getopt::Long qw(:config auto_version auto_help);
use File::PathConvert qw(abs2rel);
use File::Copy::Recursive qw(fcopy);

my $do_new_versions;
my $do_new_symlinks;
my $do_print_range;
my $do_hardlink;
my $do_commit;
my $do_rebuild_tree;
my $do_emancipate;
my $do_de_emancipate;

my $apply;
my $apply_repo;
my $apply_success;

my $outdir;
my $indir = ".";

my $branch = '@{February.1}';
my $commit_message_file;

my $commit_commitdate;
my $commit_committer;
my $commit_authordate;
my $commit_author;
my $arg_recurse=10;

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
    "commit!" => \$do_commit,
    "commit-message-file=s" => \$commit_message_file,
    "commit-authordate=s" => \$commit_authordate,
    "commit-author=s" => \$commit_author,
    "commit-commitdate=s" => \$commit_commitdate,
    "commit-committer=s" => \$commit_committer,
    "recurse=i" => \$arg_recurse,
    "emancipate!" => \$do_emancipate,
    "de-emancipate!" => \$do_de_emancipate,
    ) or die;

$apply_repo =~ s/\/*$/\//;
$apply_repo =~ s/^\.\///;

$outdir =~ s/\/*$//;
$indir =~ s/\/*$//;

chdir($indir) or die;

my $pwd = `pwd`;
chomp($pwd);


my %repos;



sub repos_new {
    my ($version) = @_;

    if (! -d "$outdir/manifests/$version/manifests") {
	nsystem("mkdir -p $outdir/manifests/$version/manifests") or die;
	nsystem("cp -a $pwd/.repo/local_manifests $outdir/manifests/$version/") or die;
	nsystem("git clone $pwd/.repo/manifests $outdir/manifests/$version/manifests") or die;
	nsystem("(cd $outdir/manifests/$version/manifests && git checkout $version && cp -a .git ../manifests.git && ln -s manifests/default.xml ../manifest.xml && git config remote.origin.url git://github.com/Quarx2k/android.git)") or die;
    }

    chdir($pwd);
    my @res = `python $pwd/.repo/repo/main.py --wrapper-version=1.21 --repo-dir=$outdir/manifests/$version -- list --url`;
    map { $_ = [split(/ : /)] } @res;

    map { $_->[0] =~ s/\/*$/\//; } @res;

    for my $r (@res) {
	my ($repopath, $manifest_name, $manifest_url, $manifest_revision) = @$r;
	$repos{$repopath}{manifest_name} = $manifest_name;
	$repos{$repopath}{manifest_url} = $manifest_url;
	$repos{$repopath}{manifest_revision} = $manifest_revision;
	$repos{$repopath}{path} = "$outdir/import/$repopath";
    }

    my @repos = map { $_->[0] } @res;

    map { chomp; s/^\.\///; s/\/*$/\//; } @repos;

    unshift @repos, ".repo/repo/";
    unshift @repos, ".repo/manifests/";

    return @repos;
}

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

    $item->{repopath} =~ s/\/*$//;
    my $repopath = $item->{repopath};

    $item->{gitpath} =~ s/\/*$//;

    $item->{gitpath} = substr($repopath, length($item->{repo}));

    my $olditem = $items{$repopath};

    if ($olditem) {
	my $repo = $item->{repo};
	if (length($olditem->{repo}) > length($item->{repo})) {
	    $repo = $olditem->{repo};
	}

	for my $key (keys %$item) {
	    $olditem->{$key} = $item->{$key};
	}
	$item = $olditem;
	$item->{repo} = $repo;
	$item->{gitpath} = substr($repopath, length($repo));
    } else {
	$items{$repopath} = $item;
    }

    return if $repopath eq ".";

    my $dir = dirname($repopath);
    if (!$items{$dir} ||
	$item->{changed} > $items{$dir}{changed}) {
	store_item($item->{changed} ? {repopath=>dirname($repopath), changed=>1} : {repopath=>dirname($repopath)});
    }
}

sub git_walk_tree {
    my ($repo, $gitpath, $head) = @_;

    my @lstree_lines = split(/\0/, `git ls-tree '$head':'$gitpath' -z`);

    my @modes = map { /^(\d\d\d)(\d\d\d) ([^ ]*) ([^ \t]*)\t(.*)$/ or die; { mode=> $2, extmode => $1, path => $gitpath.(($gitpath eq "")?"":"/").$5 } } @lstree_lines;

    for my $m (@modes) {
	my $path = $m->{path};
	next unless $items{dirname($repo.$path)}{changed};

	if ($m->{extmode} eq "120") {
	    store_item({oldtype=>"link", repopath=>$repo.$path, repo=>$repo});
	} elsif ($m->{extmode} eq "100") {
	    store_item({oldtype=>"file", repopath=>$repo.$path, repo=>$repo});
	} elsif ($m->{extmode} eq "040") {
	    store_item({oldtype=>"dir", repopath=>$repo.$path, repo=>$repo});
	    git_walk_tree($repo, $path, $head)
		if $items{$repo.$path}{changed};
	} else {
	    die "unknown mode";
	}
    }
}

# see comment at end of file
nsystem("rm $outdir/repo-overlay 2>/dev/null"); #XXX use as lock

nsystem("mkdir -p $outdir/import $outdir/export") or die;
-d "$outdir/import/.git" or die;

if ($do_new_versions) {
    nsystem("rm -rf $outdir/versions/*");
    nsystem("rm -rf $outdir/import/.pipcet-ro/versions/*");
}

my %version;
my %rversion;

my $version_fh;
open $version_fh, "cat /dev/null \$(find $outdir/import/.pipcet-ro/versions/ -name version.txt)|";
while (<$version_fh>) {
    chomp;

    my $path;
    my $head;
    my $versioned_name;

    if (($path, $head, $versioned_name) = /^(.*): (.*) (.*)$/) {
	if ($head ne "") {
	    $version{$path} = $head;
	    $rversion{$head} = $path;
	}
	$repos{$path}{versioned_name} = $versioned_name;
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
    if ($last =~ /[^0-9a-f]/ or
	length($last) < 10) {
	return undef;
    } else {
	return $last;
    }
}

sub git_parents {
    my ($commit) = @_;

    my $i = 1;
    my $p;
    my @res;

    while (defined($p = revparse("$commit^$i"))) {
	push @res, $p;
	$i++;
    }

    return @res;
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
    chdir($repo) or die;
    die if $version{$repo} eq "";
    if (grep { $_ eq $version{$repo} } git_parents($apply)) {
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
	store_item({repopath=>$dir, changed=>1});
    }

    my @files = split(/\0/, `find -name .git -prune -o -type f -print0`);

    for my $file (@files) {
	$file =~ s/^\.\///;
	$file =~ s/\/*$//;
	store_item({repopath=>$file, changed=>1});
    }

    chdir($pwd);
}

if ($do_new_symlinks or !defined($apply_repo)) {
    nsystem("rm -rf $outdir/import/*");
    nsystem("rm -rf $outdir/export/*");
    nsystem("rm -rf $outdir/import/.repo");
    nsystem("rm -rf $outdir/export/.repo");
} elsif (defined($apply_repo)) {
    # rm -rf dangling-symlink/ doesn't delete anything. Learn
    # something new every day.
    nsystem("rm -rf $outdir/import/" . ($apply_repo =~ s/\/$//r));
    nsystem("rm -rf $outdir/export/" . ($apply_repo =~ s/\/$//r));
}

my @repos;
if (defined($apply) and defined($apply_repo) and
    !$do_new_symlinks and !$do_new_versions) {
    my $repo = ($apply_repo =~ s/\/*$/\//r);

    $repos{$repo}{name} = $repos{$repo}{versioned_name};

    @repos = ($repo);
} else {
    @repos = repos_new(get_head(".repo/manifests/"));

    map { $repos{$_}{name} = $repos{$_}{manifest_name} } @repos;
}

sub get_head {
    my ($repo) = @_;

    return $repos{$repo}{head} if defined($repos{$repo}{head});

    $repos{$repo}{repo} = $repo;
    chdir($pwd);
    chdir($repo) or return undef;
    my $branch = `git log -1 --reverse --pretty=oneline --until='February 1'|cut -c -40`;
    chomp($branch);
    my $head;
    if ($do_new_versions) {
	$head = revparse($branch) // revparse("HEAD");
    } else {
	$head = $version{$repo} // revparse($branch) // revparse("HEAD");
    }

    die if $head eq "";

    if (!defined($rversion{$head}) or
	$head ne $version{$repo}) {
    } elsif ($version{$rversion{$head}} ne $head) {
	die "version mismatch";
    }

    my $oldhead = $head;
    my $newhead = $head;

    if (defined($apply)) {
	if (grep { $_ eq $head } git_parents($apply)) {
	    $newhead = $apply;
	    warn "successfully applied $apply to $repo";
	    $apply_success = 1;
	}
    }
    if (!$do_emancipate) {
	$head = $newhead;
    }

    $version{$repo} = $head;
    $repos{$repo}{head} = $head;
    $repos{$repo}{oldhead} = $oldhead;
    $repos{$repo}{newhead} = $newhead;

    chdir($pwd);

    return $head;
}

store_item({repopath=>"", changed=>1});
store_item({repopath=>".", changed=>1});
for my $repo (@repos) {
    my $head = get_head($repo);
    my $oldhead = $repos{$repo}{oldhead};
    my $newhead = $repos{$repo}{newhead};

    chdir($pwd);
    chdir($repo);

    store_item({repopath=>($repo =~ s/\/*$//r), oldtype=>"dir", repo=>$repo});

    if (!defined($head)) {
	store_item({repopath=>($repo =~ s/\/*$//r), changed=>1});
	$repos{$repo}{deleted} = 1;
	next;
    }

    my %diffstat;
    if ($oldhead eq $newhead) {
	#%diffstat = reverse split(/\0/, `git diff $head --name-status -z`);
    } else {
	%diffstat = reverse split(/\0/, `git diff $oldhead..$newhead --name-status -z`);
    }

    for my $path (keys %diffstat) {
	my $stat = $diffstat{$path};

	if ($stat eq "M") {
	    store_item({repopath=>$repo.$path, status=>" M", changed=>1});
	} elsif ($stat eq "A") {
	    store_item({repopath=>$repo.$path, oldtype=>"none", repo=>$repo, status=>"??", changed=>1});
	} elsif ($stat eq "D") {
	    store_item({repopath=>$repo.$path, status=>" D", changed=>1});
	} else {
	    die "$stat $path";
	}
    }

    if (!$items{$repo =~ s/\/$//r}{changed}) {
	next;
    }

    if ($repo eq ".repo/manifests/") {
	$do_rebuild_tree = 1;
	warn "rebuild tree!"
    }

    git_walk_tree($repo, "", $head);
}

chdir($pwd);
for my $item (values %items) {
    if (-l $item->{repopath}) {
	$item->{newtype} = "link";
    } elsif (!-e $item->{repopath}) {
	$item->{newtype} = "none";
    } elsif (-d $item->{repopath}) {
	$item->{newtype} = "dir";
    } elsif (-f $item->{repopath}) {
	$item->{newtype} = "file";
    } else {
	die;
    }

    $item->{oldtype} = $item->{newtype} unless defined($item->{oldtype});
}

chdir($outdir);
for my $item (values %items) {
    my $repo = $item->{repo};
    next unless defined($repos{$repo}{head}) or $do_new_symlinks;
    my $repopath = $item->{repopath};
    next if $repopath eq "" or $repopath eq ".";
    next unless $items{dirname($repopath)}{changed};
    my $gitpath = $item->{gitpath};
    my $type = $item->{newtype};
    my $oldtype = $item->{oldtype};
    my $head = $repos{$repo}{head};

    if ($oldtype eq "dir") {
	my $dir = $repopath;

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
	my $dir = $repopath;

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
	my $file = $gitpath;

	if ($item->{changed}) {
	    cat_file($repo, $head, $file, "import/$repo$file");
	} else {
	    symlink_relative("$outdir/repo-overlay/$repo$file", "import/$repo$file") or die;
	}
    }
    if ($type eq "file") {
	my $file = $gitpath;

	if ($item->{changed}) {
	    copy_or_hardlink("$pwd/$repo$file", "export/$repo$file") or die;
	} else {
	    symlink_relative("$outdir/repo-overlay/$repo$file", "export/$repo$file") or die;
	}
    }
    if ($oldtype eq "link") {
	my $file = $gitpath;

	symlink_absolute(`(cd $pwd/$repo; git cat-file blob '$head':'$file')`, "import/$repo$file") or die;
    }
    if ($type eq "link") {
	my $file = $gitpath;

	copy_or_hardlink("$pwd/$repo$file", "export/$repo$file") or die;
    }
}

chdir($pwd);

if ($apply_success or $do_new_versions) {
    for my $repo (@repos) {
	mkdirp("$outdir/import/.pipcet-ro/versions/$repo");
	open $version_fh, ">$outdir/import/.pipcet-ro/versions/$repo"."version.txt";
	print $version_fh "$repo: ".$version{$repo}." $repos{$repo}{name}\n";
	close $version_fh;
    }
}

copy_or_hardlink("$pwd/README.md", "$outdir/import/") or die;
copy_or_hardlink("$pwd/README.md", "$outdir/export/") or die;
copy_or_hardlink("$pwd/Makefile", "$outdir/import/") or die;
copy_or_hardlink("$pwd/Makefile", "$outdir/export/") or die;

# this must come after all symbolic links have been created, so ln
# doesn't get confused about which relative path to use.
nsystem("ln -s $pwd $outdir/repo-overlay");

if ($do_commit and defined($commit_message_file)) {
    chdir("$outdir/import");
    if ($do_emancipate) {
	nsystem("git add --all; git commit -m 'emancipation commit for $apply' " .
		(defined($commit_authordate) ? "--date '$commit_authordate' " : "") .
		(defined($commit_author) ? "--author '$commit_author' " : ""));
    } else {
	nsystem("git add --all; git commit --allow-empty -F $commit_message_file " .
		(defined($commit_authordate) ? "--date '$commit_authordate' " : "") .
		(defined($commit_author) ? "--author '$commit_author' " : ""));
    }
}

# useful commands:
#  repo-overlay.pl -- sync repository to export/ import/
#  diff -ur repo-overlay/ export/|(cd repo-overlay; patch -p1) -- sync export/ to repository (doesn't handle new/deleted files)
#  diff -urNx .git -x .repo -x out -x out-old repo-overlay/ export/|(cd repo-overlay; patch -p1)

# perl ~/repo-tools/repo-overlay.pl --new-symlinks --new-versions --out=/home/pip/tmp-repo-overlay
# perl ~/repo-tools/repo-log.pl --just-shas|tac|while read && echo $REPLY && sh -c "perl ~/repo-tools/repo-overlay.pl $REPLY --out=/home/pip/tmp-repo-overlay"; do true; done
# perl ~/repo-tools/repo-log.pl --just-shas|tac|while read; do echo $REPLY; sh -c "perl ~/repo-tools/repo-overlay.pl $REPLY --out=/home/pip/tmp-repo-overlay"; done

# perl ~/repo-tools/repo-log.pl --just-shas --commit-dir=/home/pip/tmp-repo-overlay/commits|tac|while read; do echo "$REPLY"; sh -c "perl ~/repo-tools/repo-overlay.pl --emancipate $REPLY --out=/home/pip/tmp-repo-overlay"; sh -c "perl ~/repo-tools/repo-overlay.pl $REPLY --out=/home/pip/tmp-repo-overlay"; done

# perl ~/repo-tools/repo-log.pl --just-shas --commit-dir=/home/pip/tmp-repo-overlay/commits|tac|while read; do echo "$REPLY"; sh -c "perl ~/repo-tools/repo-overlay.pl --commit --emancipate $REPLY --out=/home/pip/tmp-repo-overlay"; sh -c "perl ~/repo-tools/repo-overlay.pl --commit $REPLY --out=/home/pip/tmp-repo-overlay"; done

exit(0);

# Local Variables:
# eval: (add-hook 'before-save-hook (quote whitespace-cleanup))
# End:
