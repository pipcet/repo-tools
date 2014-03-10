#!/usr/bin/perl
use strict;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Getopt::Long qw(:config auto_version auto_help);
use File::PathConvert qw(abs2rel);
use File::Copy::Recursive qw(fcopy);
use Carp::Always;

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
my $apply_repo_name;
my $apply_last_manifest;

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
    "apply-repo-name=s" => \$apply_repo_name,
    "apply-last-manifest" => \$apply_last_manifest,
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

if (defined($commit_commitdate) and !$do_emancipate) {
    print "$commit_commitdate\n";
}

my $repos;

$repos->{".repo/manifests/"} = {
    name => ".repo/manifests",
    relpath => ".repo/manifests/",
    gitpath => "$pwd/.repo/manifests/",
};

sub repos_get_gitpath {
    my ($repos, $repo) = @_;
    my $gitpath = $repos->{$repo}{gitpath};

    if ($gitpath eq "" or ! -e $gitpath) {
	my $url = $repos->{$repo}{manifest_url};

	if (!($url=~/\/\//)) {
	    # XXX why is this strange fix needed?
	    $url = "https://github.com/" . $repos->{$repo}{name};
	}

	die "no repository for " . $repos->{$repo}{name} . " url $url";

	#system("git clone $url $outdir/other-repositories/" . $repos->{$repo}{name});
	return undef;
    }

    return $gitpath;
}

sub begins_with {
    my ($a,$b,$noprefix) = @_;

    my $ret = substr($a, 0, length($b)) eq $b;

    if ($ret and $noprefix) {
	$$noprefix = substr($a, length($b));
    }

    return $ret;
}

sub prefix {
    my ($a, $b) = @_;
    my $ret;

    die unless begins_with($a, $b, \$ret);

    return $ret;
}

my %repo_master_cache = ("" => "$pwd");
sub repo_master {
    my ($name) = @_;

    if (exists($repo_master_cache{$name})) {
	return $repo_master_cache{$name};
    }

    if ($name eq "") {
	my $master = "$pwd";

	return $master;
    }

    my $master = readlink("$outdir/repos-by-name/$name/repo");

    die "no master for $name" unless(defined($master));

    $repo_master_cache{$name} = $master;

    return $master;
}

sub setup_repo_links {
    system("rm -rf $outdir/manifests/HEAD");
    my $head_repos = repos("HEAD");

    system("rm -rf $outdir/repos-by-name");
    for my $repo (values %$head_repos) {
	my $name = $repo->{manifest_name} // $repo->{name};
	my $linkdir = "$outdir/repos-by-name/" . $name . "/";

	mkdirp($linkdir);
	symlink_absolute("$pwd/" . $repo->{relpath}, $linkdir . "repo");
    }

    my @other_repos = split(/\0/, `find $outdir/other-repositories -name '.git' -prune -print0`);
    map { s/\.git$// } @other_repos;

    for my $repo (@other_repos) {
	my $name = prefix($repo, "$outdir/other-repositories/");
	my $linkdir = "$outdir/repos-by-name/" . $name . "/";

	mkdirp($linkdir);
	symlink_absolute($repo, $linkdir . "repo");
    }
}

sub repos {
    my ($version) = @_;
    my $repos = { };

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
	$repos->{$repopath}{relpath} = $repopath;
	$repos->{$repopath}{manifest_name} = $manifest_name;
	$repos->{$repopath}{manifest_url} = $manifest_url;
	$repos->{$repopath}{manifest_revision} = $manifest_revision;
	$repos->{$repopath}{path} = "$outdir/import/$repopath";
	$repos->{$repopath}{gitpath} = "$outdir/repos-by-name/$manifest_name/repo";
    }

    my @repos = map { $_->[0] } @res;

    map { chomp; s/^\.\///; s/\/*$/\//; } @repos;

    unshift @repos, ".repo/repo/";
    unshift @repos, ".repo/manifests/";

    $repos->{".repo/repo/"}{path} = "$outdir/.repo/repo/";
    $repos->{".repo/manifests/"}{path} = "$outdir/.repo/manifests/";

    $repos->{".repo/repo/"}{gitpath} = "$outdir/repos-by-name/.repo/repo/repo";
    $repos->{".repo/manifests/"}{gitpath} = "$outdir/repos-by-name/.repo/manifests/repo";

    $repos->{".repo/repo/"}{name} = ".repo/repo";
    $repos->{".repo/manifests/"}{name} = ".repo/manifests";

    $repos->{".repo/repo/"}{relpath} = ".repo/repo/";
    $repos->{".repo/manifests/"}{relpath} = ".repo/manifests/";

    return $repos;
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
    my $noprefix;
    if (begins_with($src, "$pwd/", \$noprefix)) {
	$src = "$outdir/repo-overlay/$noprefix";
    }
    my $relsrc = abs2rel($src, $outdir."/".dirname($dst));

    mkdirp(dirname($dst)) or die "cannot make symlink $dst -> $relsrc";

    symlink($relsrc, $dst) or die "cannot make symlink $dst -> $relsrc";
}

sub symlink_absolute {
    my ($src, $dst) = @_;

    mkdirp(dirname($dst)) or die;

    symlink($src, $dst) or die "cannot make symlink $dst -> $src";
}

sub copy_or_hardlink {
    my ($src, $dst) = @_;

    fcopy($src, $dst);

    return 1;
}

sub cat_file {
    my ($master, $branch, $file, $dst) = @_;

    mkdirp(dirname($dst)) or die;

    if ($branch ne "") {
	nsystem("(cd $master; git cat-file blob '$branch':'$file') > $dst") or die;
    } else {
	nsystem("cat $master/$file > $dst") or die;
    }
}

my %items;

sub store_item {
    my ($item) = @_;

    $item->{repopath} =~ s/\/*$//;
    my $repopath = $item->{repopath};

    $item->{changed} = 1 if $repopath eq "";

    $item->{gitpath} = prefix($repopath . "/", $item->{repo});
    $item->{gitpath} =~ s/\/*$//;

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
	$item->{gitpath} = prefix($repopath . "/", $repo);
	$item->{gitpath} =~ s/\/*$//;
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
    my ($repo, $itempath, $head) = @_;
    my $repopath = $repos->{$repo}{path};
    my $gitpath = repos_get_gitpath($repos, $repo);

    die unless defined($gitpath);
    chdir($gitpath);

    my @lstree_lines = split(/\0/, `git ls-tree '$head':'$itempath' -z`);

    my @modes = map { /^(\d\d\d)(\d\d\d) ([^ ]*) ([^ \t]*)\t(.*)$/ or die; { mode=> $2, extmode => $1, path => $itempath.(($itempath eq "")?"":"/").$5 } } @lstree_lines;

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

sub read_versions {
    my ($repos) = @_;

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
	    $repos->{$path}{versioned_name} = $versioned_name;
	}
    }
    close $version_fh;
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
    read_versions({});

    chdir($pwd);
    chdir($apply_repo);
    print "$version{$apply_repo}.." . revparse("HEAD") . "\n";

    exit(0);
}

if (defined($apply) and defined($apply_repo)) {
    die if $apply eq "";

    read_versions({});

    my $repo = $apply_repo;
    chdir($repo) or die;
    if ($version{$repo} eq "") {
	warn "no version for $repo"
    } elsif (grep { $_ eq $version{$repo} } git_parents($apply)) {
	warn "should be able to apply commit $apply to $apply_repo.";
    } else {
	my $msg = "cannot apply commit $apply to $repo @" . $version{$repo} . " != " . revparse($apply . "^") . "\n";
	if (nsystem("git merge-base --is-ancestor $apply $version{$repo}")) {
	    exit(0);
	}
	if (nsystem("git merge-base --is-ancestor $apply HEAD") &&
	    nsystem("git merge-base --is-ancestor $version{$repo} HEAD")) {
	    exit(0);
	    $msg .= "but all will be good in the future.\n";
	    die $msg;
	}
	if (nsystem("git merge-base --is-ancestor $version{$repo} $apply")) {
	    $msg .= "missing link for $repo\n";
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
}
chdir($pwd);

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

$repos = repos(get_head(".repo/manifests/"));

for my $repo (values %$repos) {
    $repo->{name} = $repo->{manifest_name} // $repo->{name};
}

read_versions($repos);

if (defined($apply) and defined($apply_repo) and
    !$do_new_symlinks and !$do_new_versions) {
    #XXX
    $repos->{$apply_repo}{name} = $repos->{$apply_repo}{versioned_name};
}

if ($do_new_symlinks) {
    setup_repo_links();
}

my @repos = sort keys %$repos;

if (defined($apply) and defined($apply_repo) and !defined($apply_repo_name)) {
    my $manifest = $apply_last_manifest // "HEAD";
    my $backrepos = repos($manifest);
    my $name = $backrepos->{$apply_repo}{manifest_name};

    die "cannot resolve repo $apply_repo" if (!defined($name));

    $apply_repo_name = $name;
    $repos->{$apply_repo} = $backrepos->{$apply_repo};
    $repos->{$apply_repo}{name} = $name;

    warn "resolved $apply_repo to $name\n";
}

if (defined($apply) and defined($apply_repo) and
    !$do_new_symlinks and !$do_new_versions) {
    @repos = ($apply_repo);
}

sub get_head {
    my ($repo) = @_;

    return $repos->{$repo}{head} if exists($repos->{$repo}{head});

    $repos->{$repo}{repo} = $repo;

    my $gitpath = repos_get_gitpath($repos, $repo);

    return undef unless defined($gitpath);
    chdir($gitpath);

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
    $repos->{$repo}{head} = $head;
    $repos->{$repo}{oldhead} = $oldhead;
    $repos->{$repo}{newhead} = $newhead;

    chdir($pwd);

    return $head;
}

store_item({repopath=>"", changed=>1});
store_item({repopath=>".", changed=>1});
for my $repo (@repos) {
    my $head = get_head($repo);
    my $oldhead = $repos->{$repo}{oldhead};
    my $newhead = $repos->{$repo}{newhead};

    my $gitpath = repos_get_gitpath($repos, $repo);
    next unless defined($gitpath);

    chdir($gitpath);

    store_item({repopath=>($repo =~ s/\/*$//r), oldtype=>"dir", repo=>$repo});
    if (begins_with(repo_master($repos->{$repo}{name}), "$pwd/")) {
	store_item({repopath=>dirname($repo), oldtype=>"dir"});
    } else {
	store_item({repopath=>dirname($repo), oldtype=>"dir", changed=>1});
    }

    if (!defined($head)) {
	store_item({repopath=>($repo =~ s/\/*$//r), changed=>1});
	$repos->{$repo}{deleted} = 1;
	next;
    }

    my %diffstat;
    if ($oldhead eq $newhead) {
	%diffstat = reverse split(/\0/, `git diff $head --name-status -z`);
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
    next unless defined($repos->{$repo}{head}) or $do_new_symlinks;
    my $repopath = $item->{repopath};
    next if $repopath eq "" or $repopath eq ".";
    next unless $items{dirname($repopath)}{changed};
    my $gitpath = $item->{gitpath};
    my $type = $item->{newtype};
    my $oldtype = $item->{oldtype};
    my $head = $repos->{$repo}{head};

    if ($oldtype eq "dir") {
	my $dir = $repopath;

	die if $dir eq ".";
	my $dirname = $dir;
	while(!$items{$dirname}{changed}) {
	    ($dir, $dirname) = ($dirname, dirname($dirname));
	}

	if (!$items{$dir}{changed}) {
	    if (! (-e "import/$dir" || -l "import/$dir")) {
		symlink_relative(repo_master($repos->{$repo}{name}) . "/$gitpath", "import/$dir") or die;
	    }
	} else {
	    mkdirp("import/$dir")
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
		symlink_relative(repo_master($repos->{$repo}{name}) . "/$gitpath", "export/$dir") or die;
	    }
	} else {
	    mkdirp("import/$dir")
	}
    }
    if ($oldtype eq "file") {
	my $file = $gitpath;

	if ($item->{changed} or $repos->{$repo}{name} eq "") {
	    cat_file(repo_master($repos->{$repo}{name}, 1), $head, $file, "import/$repo$file");
	} else {
	    symlink_relative(repo_master($repos->{$repo}{name}) . "/$file", "import/$repo$file") or die;
	}
    }
    if ($type eq "file") {
	my $file = $gitpath;

	if ($item->{changed} or $repos->{$repo}{name} eq "") {
	    copy_or_hardlink("$pwd/$repo$file", "export/$repo$file") or die;
	} else {
	    symlink_relative(repo_master($repos->{$repo}{name}) . "/$file", "export/$repo$file") or die;
	}
    }
    if ($oldtype eq "link") {
	my $file = $gitpath;
	my $dest = `(cd $pwd/$repo; git cat-file blob '$head':'$file')`;
	chomp($dest);
	symlink_absolute($dest, "import/$repo$file") or die;
    }
    if ($type eq "link") {
	my $file = $gitpath;

	copy_or_hardlink("$pwd/$repo$file", "export/$repo$file") or die;
    }
}

copy_or_hardlink("$pwd/README.md", "$outdir/import/") or die;
copy_or_hardlink("$pwd/README.md", "$outdir/export/") or die;
copy_or_hardlink("$pwd/Makefile", "$outdir/import/") or die;
copy_or_hardlink("$pwd/Makefile", "$outdir/export/") or die;

# this must come after all symbolic links have been created, so ln
# doesn't get confused about which relative path to use.
nsystem("ln -s $pwd $outdir/repo-overlay") or die;

if ($do_commit and defined($commit_message_file)) {
    chdir("$outdir/import");
    if ($do_emancipate) {
	nsystem("git add --all; git commit -m 'emancipation commit for $apply' " .
		(defined($commit_authordate) ? "--date '$commit_authordate' " : "") .
		(defined($commit_author) ? "--author '$commit_author' " : ""));
    } else {
	nsystem("git add --all; git commit --allow-empty -F $commit_message_file " .
		(defined($commit_authordate) ? "--date '$commit_authordate' " : "") .
		(defined($commit_author) ? "--author '$commit_author' " : "")) or die;
    }
}

if ($apply_success or $do_new_versions and !$do_emancipate) {
    for my $repo (@repos) {
	my $version_fh;

	mkdirp("$outdir/import/.pipcet-ro/versions/$repo");
	open $version_fh, ">$outdir/import/.pipcet-ro/versions/$repo"."version.txt";
	print $version_fh "$repo: ".$repos->{$repo}{head}." ".$repos->{$repo}{name}."\n";
	close $version_fh;
    }

    if ($do_commit) {
	nsystem("git add --all; git commit -m 'versioning commit for $apply' " .
		(defined($commit_authordate) ? "--date '$commit_authordate' " : "") .
		(defined($commit_author) ? "--author '$commit_author' " : "")) or die;
    }
}

chdir($pwd);

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
