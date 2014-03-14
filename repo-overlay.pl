#!/usr/bin/perl
use strict;
no warnings "experimental::lexical_subs";
use feature 'lexical_subs';

use File::Basename qw(dirname);
use File::Path qw(make_path);
use Getopt::Long qw(:config auto_version auto_help);
use File::PathConvert qw(abs2rel);
use File::Copy::Recursive qw(fcopy);
use Carp::Always;

use Git::Repository;

my $do_new_versions;
my $do_new_symlinks;
my $do_print_range;
my $do_hardlink;
my $do_commit;
my $do_rebuild_tree;
my $do_emancipate;
my $do_de_emancipate;
my $do_wd;
my $do_head;

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

my $date;

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
    "apply-use-manifest=s" => \$apply_last_manifest,
    "commit!" => \$do_commit,
    "commit-message-file=s" => \$commit_message_file,
    "commit-authordate=s" => \$commit_authordate,
    "commit-author=s" => \$commit_author,
    "commit-commitdate=s" => \$commit_commitdate,
    "commit-committer=s" => \$commit_committer,
    "recurse=i" => \$arg_recurse,
    "emancipate!" => \$do_emancipate,
    "de-emancipate!" => \$do_de_emancipate,
    "date=s" => \$date,
    ) or die;

if (defined($apply_repo)) {
    $apply_repo =~ s/\/*$/\//;
    $apply_repo =~ s/^\.\///;
}

$outdir =~ s/\/*$//;
$indir =~ s/\/*$//;

chdir($indir) or die;

my $pwd = `pwd`;
chomp($pwd);

if (defined($commit_commitdate) and !$do_emancipate) {
    print "$commit_commitdate\n";
}

# like die, but without the dying part
our sub retire {
    warn @_;

    exit(0);
}

# like system(), but not the return value and echo command
our sub nsystem {
    my ($cmd) = @_;

    warn "running $cmd";

    return !system($cmd);
}

our sub oldrevparse {
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

our sub begins_with {
    my ($a,$b,$noprefix) = @_;

    my $ret = substr($a, 0, length($b)) eq $b;

    if ($ret and $noprefix) {
	$$noprefix = substr($a, length($b));
    }

    return $ret;
}

our sub prefix {
    my ($a, $b) = @_;
    my $ret;

    die unless begins_with($a, $b, \$ret);

    return $ret;
}

package Repository;

sub mdata {
    my ($r) = @_;

    return $r->{mdata};
}

sub url {
    my ($r) = @_;

    return $r->{url};
}

sub path {
    my ($r) = @_;

    return $r->{path};
}

sub relpath {
    my ($r) = @_;

    return $r->{relpath};
}

sub name {
    my ($r) = @_;

    return $r->{name};
}

sub new {
    my ($class, $mdata, $path, $name, $url, $fullpath, $gitpath, $revision) = @_;
    my $repo = bless {}, $class;

    $repo->{mdata} = $mdata;
    $repo->{relpath} = $path;
    $repo->{name} = $name;
    $repo->{url} = $url;
    $repo->{gitpath} = $gitpath;
    $repo->{path} = $fullpath;
    $repo->{revision} = $revision;

    return $repo;
}

package Repository::Git;
use parent -norequire, "Repository";

sub gitrepository {
    my ($r) = @_;

    return $r->{gitrepository} if ($r->{gitrepository});

    return $r->{gitrepository} = new Git::Repository(work_tree => $r->{gitpath});
}

sub revparse {
    my ($r, $head) = @_;
    my $last = $r->git("rev-parse" => $head, {fatal=>-128, quiet=>1});
    chomp($last);
    if ($last =~ /[^0-9a-f]/ or
	length($last) < 10) {
	return undef;
    } else {
	return $last;
    }
}

sub git_parents {
    my ($r, $commit) = @_;

    my $i = 1;
    my $p;
    my @res;

    while (defined($p = $r->revparse("$commit^$i"))) {
	push @res, $p;
	$i++;
    }

    return @res;
}

# find an oldest ancestor of $head that's still a descendant of $a and $b.
sub git_find_descendant {
    my ($r, $head, $a, $b) = @_;

    my $d;

    for my $p ($r->git_parents($head)) {
	if (nsystem("git merge-base --is-ancestor $p $a") and
	    nsystem("git merge-base --is-ancestor $p $b")) {
	    return $r->git_find_descendant($p, $a, $b);
	}
    }

    return $head;
}

sub git {
    my ($r, @args) = @_;

    return $r->gitrepository->run(@args);
}

package Repository::Git::Head;
use parent -norequire, "Repository::Git";

sub head {
    my ($r) = @_;

    return $r->{head} if exists($r->{head});

    my $mdata = $r->mdata;
    my $repo = $r->{relpath};
    my $date = $mdata->{date} // "";

    my $branch = $r->git(log => "-1", "--reverse", "--pretty=oneline", "--until=$date");
    $branch = substr($branch, 0, 40);

    my $head;
    if ($do_new_versions) {
	$head = $r->revparse($branch) // $r->revparse("HEAD");
    } else {
	$mdata->read_versions();
	$head = $mdata->{version}{$repo} // $r->revparse($branch) // $r->revparse("HEAD");
    }

    if ($repo eq ".repo/manifests/") {
	warn "branch $branch head $head date $date";
    }

    die if $head eq "";

    my $oldhead = $head;
    my $newhead = $head;

    if (defined($apply) && $apply_repo eq $repo) {
	if (grep { $_ eq $head } $r->git_parents($apply)) {
	    $newhead = $apply;
	    warn "successfully applied $apply to $repo";
	    $apply_success = 1;
	} else {
	    warn "head $head didn't match any of " . join(", ", $r->git_parents($apply)) . " to be replaced by $apply";
	}
    }
    if (!$do_emancipate) {
	$head = $newhead;
    }

    $r->{oldhead} = $oldhead;
    $r->{newhead} = $newhead;
    $r->{head} = $head;

    chdir($pwd);

    return $head;
}

package Repository::Git::WD;
use parent -norequire, "Repository::Git";


package DirState;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Getopt::Long qw(:config auto_version auto_help);
use File::PathConvert qw(abs2rel);
use File::Copy::Recursive qw(fcopy);
use Carp::Always;

sub items {
    my ($dirstate) = @_;

    return map { $dirstate->{items}{$_}} sort keys %{$dirstate->{items}};
}

sub changed {
    my ($dirstate, $item) = @_;

    return $dirstate->{items}{$item} && $dirstate->{items}{$item}{changed};
}

sub repos {
    my ($dirstate) = @_;
    my $mdata = $dirstate->{mdata};

    return $mdata->repos;
}

sub store_item {
    my ($dirstate, $path, $item) = @_;
    my $mdata = $dirstate->{mdata};
    $item->{repopath} = $path;

    $item->{repopath} =~ s/\/*$//;

    my $repo = $item->{repopath};
    $repo =~ s/\/*$/\//;
    while ($repo ne "./") {
	if ($mdata->{repos}{$repo}) {
	    $item->{repo} = $repo;
	    last;
	}
	$repo = dirname($repo) . "/";
    }

    die if $item->{repopath} =~ /\/\//;
    my $repopath = $item->{repopath};

    if (defined($item->{repo}) and !defined($item->{masterpath})) {
	my $master = $mdata->repo_master($mdata->{repos}{$item->{repo}}{name});
	my $masterpath = $master . prefix($repopath, $item->{repo} =~ s/\/$//r);

	$item->{masterpath} = $masterpath;
	$item->{master} = $master;

	#warn "using default masterpath $masterpath ($master) for $repopath";
    }

    $item->{masterpath} =~ s/\/*$//;
    die if $item->{masterpath} =~ /\/\//;
    my $masterpath = $item->{masterpath};

    $item->{changed} = 1 if $repopath eq "";

    $item->{gitpath} = prefix($repopath . "/", $item->{repo});
    $item->{gitpath} =~ s/\/*$//;

    my $olditem = $dirstate->{items}{$repopath};

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
	$dirstate->{items}{$repopath} = $item;
    }

    return if $repopath eq ".";

    my $dir = dirname($repopath);
    if (!$dirstate->{items}{$dir} ||
	$item->{changed} > $dirstate->{items}{$dir}{changed}) {
	$dirstate->store_item(dirname($repopath), $item->{changed} ? {changed=>1, type=>"dir"} : {type=>"dir"});
    }
}

sub git_walk_tree_head {
    my ($dirstate, $repo, $itempath, $head) = @_;
    my $mdata = $dirstate->{mdata};
    my $r = $mdata->{repos}{$repo};

    my @lstree_lines = $r->git("ls-tree" => "$head:$itempath");

    my @modes = map { /^(\d\d\d)(\d\d\d) ([^ ]*) ([^ \t]*)\t(.*)$/ or die; { mode=> $2, extmode => $1, path => $itempath.(($itempath eq "")?"":"/").$5 } } @lstree_lines;

    for my $m (@modes) {
	my $path = $m->{path};
	next unless $dirstate->changed($repo.$path);

	if ($m->{extmode} eq "120") {
	    $dirstate->store_item($repo.$path, {type=>"link"});
	} elsif ($m->{extmode} eq "100") {
	    $dirstate->store_item($repo.$path, {type=>"file"});
	} elsif ($m->{extmode} eq "040") {
	    $dirstate->store_item($repo.$path, {type=>"dir"});
	    $dirstate->git_walk_tree_head($repo, $path, $head)
		if $dirstate->changed($repo.$path);
	} else {
	    die "unknown mode";
	}
    }
}

sub git_find_untracked {
    my ($dirstate, $dir) = @_;
    my @res;

    my @files = split(/\0/, `find -maxdepth 1 -print0`);

    for my $file (@files) {
	next if ($dirstate->{mdata}{repos}{$file . "/"});
	push @res, $file;
	if (-d $file) {
	    push @res, $dirstate->git_find_untracked($file);
	}
    }

    return @res;
}

sub scan_repo_find_changed {
    my ($dirstate, $repo) = @_;
    my $mdata = $dirstate->{mdata};
    my $r = $mdata->{repos}{$repo};
    my $head = $r->head();
    my $oldhead = $mdata->{repos}{$repo}{oldhead};
    my $newhead = $mdata->{repos}{$repo}{newhead};

    my $gitpath = $mdata->get_gitpath($repo);
    return unless defined($gitpath);

    chdir($gitpath);

    $dirstate->store_item($repo, { type=>"dir" });
    if (begins_with($mdata->repo_master($mdata->{repos}{$repo}{name}), "$pwd/")) {
	$dirstate->store_item(dirname($repo), {type=>"dir", changed=>1});
    } else {
	$dirstate->store_item(dirname($repo), {type=>"dir", changed=>1});
    }

    if (!defined($head)) {
	$dirstate->store_item($repo, {changed=>1});
	$mdata->{repos}{$repo}{deleted} = 1;
	next;
    }

    my %diffstat = reverse split(/\0/, $r->git(diff => "$head", "--name-status", "-z"));

    for my $path (keys %diffstat) {
	my $stat = $diffstat{$path};

	if ($stat eq "M") {
	    $dirstate->store_item($repo.$path, {status=>" M", changed=>1});
	} elsif ($stat eq "A") {
	    $dirstate->store_item($repo.$path, {status=>"??", changed=>1});
	} elsif ($stat eq "D") {
	    $dirstate->store_item($repo.$path, {status=>"??", changed=>1});
	} elsif ($stat eq "T") {
	    $dirstate->store_item($repo.$path, {status=>" T", changed=>1});
	} else {
	    die "$stat $path";
	}
    }

    if ($oldhead ne $newhead) {
	my %diffstat = reverse split(/\0/, $r->git(diff => "$oldhead..$newhead", "--name-status", "-z"));

	for my $path (keys %diffstat) {
	    my $stat = $diffstat{$path};

	    if ($stat eq "M") {
		$dirstate->store_item($repo.$path, {status=>" M", changed=>1});
	    } elsif ($stat eq "A") {
		$dirstate->store_item($repo.$path, {status=>"??", changed=>1});
	    } elsif ($stat eq "D") {
		$dirstate->store_item($repo.$path, {status=>" D", changed=>1});
	    } elsif ($stat eq "T") {
		$dirstate->store_item($repo.$path, {status=>" T", changed=>1});
	    } else {
		die "$stat $path";
	    }
	}
    }
}

sub new {
    my ($class, $mdata) = @_;

    die unless $mdata;

    my $dirstate = {
	items => {
	    "" => { changed => 1 },
	},
	mdata => $mdata, };

    bless $dirstate, $class;

    return $dirstate;
}

package ManifestData;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Getopt::Long qw(:config auto_version auto_help);
use File::PathConvert qw(abs2rel);
use File::Copy::Recursive qw(fcopy);
use Carp::Always;

sub read_versions {
    my ($mdata) = @_;
    my $version = { };
    my $version_fh;

    open $version_fh, "cat /dev/null \$(find $outdir/head/.pipcet-ro/versions/ -name version.txt)|";
    while (<$version_fh>) {
	chomp;
	next if /^#/;
	s/#.*$//;

	my $path;
	my $head;
	my $name;
	my $url;

	if (($path, $head, $name, $url) = /^(.*): (.*) (.*) (.*)$/) {
	    if ($head ne "") {
		$version->{$path} = $head;
	    }
	}
    }
    close $version_fh;

    return $mdata->{version} = $version;
}

sub repo_master {
    my ($mdata, $name) = @_;

    if (exists($mdata->{repo_master_cache}{$name})) {
	return $mdata->{repo_master_cache}{$name};
    }

    if ($name eq "") {
	my $master = "$pwd";

	return $master;
    }

    my $master = readlink("$outdir/repos-by-name/$name/repo");

    $master =~ s/\/$//;

    die "no master for $name" unless(defined($master));

    $mdata->{repo_master_cache}{$name} = $master;

    return $master;
}

sub get_gitpath {
    my ($mdata, $repo) = @_;
    my $gitpath = $mdata->{repos}{$repo}{gitpath};

    if ($gitpath eq "" or ! -e $gitpath) {
	my $url = $mdata->{repos}{$repo}{url};

	if (!($url=~/\/\//)) {
	    # XXX why is this strange fix needed?
	    $url = "https://github.com/" . $mdata->{repos}{$repo}{name};
	}

	warn "no repository for " . $mdata->{repos}{$repo}{name} . " url $url";

	#system("git clone $url $outdir/other-repositories/" . $mdata->{repos}{$repo}{name});
	return undef;
    }

    return $gitpath;
}

sub get_git_repository {
    my ($mdata, $repo) = @_;
    my $gitpath = $mdata->{repos}{$repo}{gitpath};

    if ($gitpath eq "" or ! -e $gitpath) {
	my $url = $mdata->{repos}{$repo}{url};

	if (!($url=~/\/\//)) {
	    # XXX why is this strange fix needed?
	    $url = "https://github.com/" . $mdata->{repos}{$repo}{name};
	}

	warn "no repository for " . $mdata->{repos}{$repo}{name} . " url $url";

	#system("git clone $url $outdir/other-repositories/" . $mdata->{repos}{$repo}{name});
	return undef;
    }

    return $gitpath;
}

sub repositories {
    my ($mdata, $pattern) = @_;

    if (defined($pattern)) {
	return $mdata->{repos}{$pattern};
    } else {
	return map { $mdata->{repos}{$_} } $mdata->repos;
    }
}

sub repos {
    my ($mdata) = @_;

    return sort keys %{$mdata->{repos}};
}

sub new {
    my ($class, $version, $date) = @_;
    my $repos_by_name_dir = "$outdir/repos-by-name";
    my $md = {};
    my $repos = {};

    $md->{date} = $date;

    my @res;
    if (defined($version)) {
	die if $version eq "";
	if (! -d "$outdir/manifests/$version/manifests") {
	    nsystem("mkdir -p $outdir/manifests/$version/manifests") or die;
	    nsystem("cp -a $pwd/.repo/local_manifests $outdir/manifests/$version/") or die;
	    nsystem("git clone $pwd/.repo/manifests $outdir/manifests/$version/manifests") or die;
	    nsystem("(cd $outdir/manifests/$version/manifests && git checkout $version && cp -a .git ../manifests.git && ln -s manifests/default.xml ../manifest.xml && git config remote.origin.url git://github.com/Quarx2k/android.git)") or die;
	}

	@res = `(cd $pwd; python $pwd/.repo/repo/main.py --wrapper-version=1.21 --repo-dir=$outdir/manifests/$version -- list --url)`;
    } else {
	@res = `(cd $pwd; python $pwd/.repo/repo/main.py --wrapper-version=1.21 --repo-dir=$pwd/.repo -- list --url)`;
    }

    map { $_ = [split(/ : /)] } @res;

    map { $_->[0] =~ s/\/*$/\//; } @res;

    for my $r (@res) {
	my ($repopath, $name, $url, $revision) = @$r;
	$repos->{$repopath} =
	    new Repository::Git::Head($md, $repopath, $name, $url,
				      "$outdir/head/$repopath",
				      "$repos_by_name_dir/$name/repo", $revision);
    }

    $repos->{".repo/repo/"} =
	new Repository::Git::Head($md, ".repo/repo/", ".repo/repo", "",
				  "$outdir/head/.repo/repo",
				  "$repos_by_name_dir/.repo/repo/repo");

    $repos->{".repo/manifests/"} =
	new Repository::Git::Head($md, ".repo/manifests/", ".repo/manifests", "",
				  "$outdir/head/.repo/manifests",
				  "$repos_by_name_dir/.repo/manifests/repo");

    $md->{repos} = $repos;

    bless $md, $class;

    return $md;
}

package main;

sub setup_repo_links {
    my $head_mdata = ManifestData->new();

    system("rm -rf $outdir/repos-by-name");
    for my $repo (values %{$head_mdata->{repos}}) {
	my $name = $repo->{name};
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

    return 1;
}

# like git diff, but between two repositories
sub git_inter_diff {
    my ($ra,$rb) = @_;

    my $temp = "/home/pip/tmp"; #XXX
    nsystem("rm -rf $temp");

    mkdir($temp);

    nsystem("cd $temp; git init");
    nsystem("cd $temp; git checkout -b empty");
    nsystem("cd $temp; git commit -m empty --allow-empty");

    if (defined($ra)) {
	my ($gitpath_a, $rev_a) = ($ra->gitpath, $ra->head);

	nsystem("cd $temp; git fetch $gitpath_a $rev_a:a");
    } else {
	nsystem("cd $temp; git checkout empty; git checkout -b a");
    }

    if (defined($rb)) {
	my ($gitpath_b, $rev_b) = ($rb->gitpath, $rb->head);

	nsystem("cd $temp; git fetch $gitpath_b $rev_b:b");
    } else {
	nsystem("cd $temp; git checkout empty; git checkout -b b");
    }

    my %diffstat = reverse split(/\0/, `cd $temp; git diff a b --name-status -z`);

    return \%diffstat;
}

sub get_base_version {
    my ($dir, $version) = @_;

    chdir($dir);

    my $head = $version // oldrevparse("HEAD");

    die if $head eq "";

    return $head;
}

sub check_apply {
    my ($mdata, $apply, $apply_repo) = @_;

    die if $apply eq "";

    my %version = %{$mdata->read_versions({})};

    my $repo = $apply_repo;
    my $r = $mdata->{repos}{$repo};
    chdir("$pwd");
    if (chdir($repo)) {
	if (!defined($r->revparse($apply))) {
	    die "commit $apply isn't in $repo.";
	}
	if ($version{$repo} eq "") {
	    warn "no version for $repo"
	} elsif (grep { $_ eq $version{$repo} } $r->git_parents($apply)) {
	    warn "should be able to apply commit $apply to $apply_repo.";
	} else {
	    my $msg = "cannot apply commit $apply to $repo @" . $version{$repo} . " != " . $r->revparse($apply . "^") . "\n";
	    if (nsystem("git merge-base --is-ancestor $apply $version{$repo}")) {
		exit(0);
	    }
	    if (nsystem("git merge-base --is-ancestor $apply HEAD") &&
		nsystem("git merge-base --is-ancestor $version{$repo} HEAD")) {
		exit(0);
		my $d = $r->git_find_descendant("HEAD", $apply, $version{$repo});
		$msg .= "but all will be good in the future.\n";
		$msg .= "merge commit:\n";

		$msg .= `git log -1 $d`;

		die $msg;
		exit(0);
	    }
	    if (nsystem("git merge-base --is-ancestor $version{$repo} $apply")) {
		$msg .= "missing link for $repo\n";
	    }

	    $msg .= " repo ancestors:\n";
	    $msg .= "".$r->revparse($version{$repo}."")."\n";
	    $msg .= "".$r->revparse($version{$repo}."~1")."\n";
	    $msg .= "".$r->revparse($version{$repo}."~2")."\n";
	    $msg .= "".$r->revparse($version{$repo}."~3")."\n";
	    $msg .= "".$r->revparse($version{$repo}."~4")."\n";
	    $msg .= " commit ancestors:\n";
	    $msg .= "".$r->revparse($apply."")."\n";
	    $msg .= "".$r->revparse($apply."~1")."\n";
	    $msg .= "".$r->revparse($apply."~2")."\n";
	    $msg .= "".$r->revparse($apply."~3")."\n";
	    $msg .= "".$r->revparse($apply."~4")."\n";

	    $msg .= "\ngit log:\n";
	    $msg .= `git log -1`;
	    $msg .= "\ncommit file:\n";
	    $msg .= `head -8 $commit_message_file`;

	    $msg .= "\n\n\n";

	    die($msg);
	}
    }
}

sub update_manifest {
    my ($mdata, $dirstate) = @_;
    my $new_mdata;
    my $repo = $apply_repo;

    $do_rebuild_tree = 1;
    warn "rebuild tree! $apply_repo";
    my $date = `git log -1 --pretty=tformat:\%ci $apply`;
    warn "date is $date";
    my $new_mdata = ManifestData->new($apply, $date);

    chdir($pwd);
    chdir($repo);

    my %rset;
    for my $repo ($new_mdata->repos, $mdata->repos) {
	$rset{$repo} = 1;
    }

    for my $repo (sort keys %rset) {
	my $r0 = $mdata->repositories($repo);
	my $r1 = $new_mdata->repositories($repo);

	if ($r0->name ne $r1->name) {
	    warn "tree rb: $repo changed from " . $r0->name . " to " . $r1->name;
	    my $diffstat = git_inter_diff($r0, $r1);

	    for my $path (keys %$diffstat) {
		my $stat = $diffstat->{$path};

		warn "$stat $path";

		if ($stat eq "M") {
		    $dirstate->store_item($repo.$path, {status=>" M", changed=>1});
		} elsif ($stat eq "A") {
		    $dirstate->store_item($repo.$path, {status=>"??", changed=>1});
		} elsif ($stat eq "D") {
		    $dirstate->store_item($repo.$path, {status=>" D", changed=>1});
		} else {
		    die "$stat $path";
		}
	    }

	    nsystem("rm -rf $outdir/head/" . ($repo =~ s/\/*$//r)) unless $repo =~ /^\/*$/;
	    nsystem("rm -rf $outdir/wd/" . ($repo =~ s/\/*$//r)) unless $repo =~ /^\/*$/;
	    $dirstate->store_item($repo, {changed=>1, type=>"dir"});
	    $dirstate->scan_repo_find_changed($repo);
	}
    }

    return $new_mdata;
}

# see comment at end of file
nsystem("rm $outdir/repo-overlay 2>/dev/null"); #XXX use as lock
nsystem("mkdir -p $outdir/head $outdir/wd") or die;
-d "$outdir/head/.git" or die;

if ($do_new_versions) {
    nsystem("rm -rf $outdir/versions/*");
    nsystem("rm -rf $outdir/head/.pipcet-ro/versions/*");
}

chdir($pwd);

if ($do_new_versions) {
    if (defined($apply_last_manifest) && !defined($date)) {
	my $mdate = `(cd '$pwd/.repo/manifests'; git log -1 --pretty=tformat:\%ci $apply_last_manifest)`;
	chomp($mdate);
	$date = $mdate;
    }
} else {
    my $v = ManifestData::read_versions({});

    $apply_last_manifest = $v->{".repo/manifests/"};
}

my $mdata_head = new ManifestData(get_base_version("$pwd/.repo/manifests", $apply_last_manifest), $date);
my $dirstate_head = new DirState($mdata_head);

if (defined($apply) and defined($apply_repo)) {
    check_apply($mdata_head, $apply, $apply_repo);
}

unless ($do_new_symlinks) {
    my @dirs = split(/\0/, `(cd '$outdir/head'; find -name .git -prune -o -type d -print0)`);

    for my $dir (@dirs) {
	$dir =~ s/^\.\///;
	$dir =~ s/\/*$//;
	$dirstate_head->store_item($dir, {changed=>1});
    }

    my @files = split(/\0/, `(cd '$outdir/head'; find -name .git -prune -o -type f -print0)`);

    for my $file (@files) {
	$file =~ s/^\.\///;
	$file =~ s/\/*$//;
	$dirstate_head->store_item($file, {changed=>1});
    }

    # XXX links
}

if (defined($apply_repo_name) and !defined($apply_repo)) {
    for my $repo ($mdata_head->repos) {
	if ($mdata_head->{repos}{$repo}{name} eq $apply_repo_name) {
	    $apply_repo = $repo;
	    warn "found repo to apply to: $apply_repo for $apply_repo_name";
	    last;
	}
    }

    retire "couldn't find repo $apply_repo_name, aborting" unless defined($apply_repo);

    $mdata_head = ManifestData->new(get_base_version("$pwd/.repo/manifests", $apply_last_manifest), $date);
    $dirstate_head = new DirState($mdata_head);

    check_apply($mdata_head, $apply, $apply_repo);
}

if ($do_new_symlinks) {
    nsystem("rm -rf $outdir/head/*");
    nsystem("rm -rf $outdir/wd/*");
    nsystem("rm -rf $outdir/head/.repo");
    nsystem("rm -rf $outdir/wd/.repo");
} elsif (defined($apply_repo)) {
    # rm -rf dangling-symlink/ doesn't delete anything. Learn
    # something new every day.
    die if $apply_repo =~ /^\/*$/;
    nsystem("rm -rf $outdir/head/" . ($apply_repo =~ s/\/$//r));
    nsystem("rm -rf $outdir/wd/" . ($apply_repo =~ s/\/$//r));
}

if (defined($apply) and defined($apply_repo) and
    !$do_new_symlinks and !$do_new_versions) {
    die if $mdata_head->{repos}{$apply_repo}{name} eq "";
}

if ($do_new_symlinks) {
    setup_repo_links();
}

if (defined($apply) and defined($apply_repo) and !defined($apply_repo_name)) {
    my $manifest = $apply_last_manifest // "HEAD";
    my $mdata = new ManifestData($manifest);
    my $name = $mdata->{repos}{$apply_repo}{name};

    unless (defined($name)) {
	warn "cannot resolve repo $apply_repo (manifest $manifest)";
	exit(0);
    }

    $apply_repo_name = $name;

    warn "resolved $apply_repo to $name\n";

    check_apply($mdata_head, $apply, $apply_repo);
}

if (defined($apply) and defined($apply_repo) and
    !$do_new_symlinks and !$do_new_versions) {

    if ($apply_repo eq ".repo/manifests/") {
	$mdata_head = update_manifest($mdata_head, $dirstate_head);
	$dirstate_head = new DirState($mdata_head);
    }

    for my $repo ($apply_repo) {
	$mdata_head->repositories($apply_repo)->head();
    }

    for my $repo ($apply_repo) {
	$dirstate_head->scan_repo_find_changed($repo);
    }

    for my $repo ($apply_repo) {
	my $mdata = $dirstate_head->{mdata};
	my $head = $mdata->repositories($repo)->head();
	$dirstate_head->git_walk_tree_head($repo, "", $head) unless $head eq "";
    }
} else {
    for my $repo ($dirstate_head->repos) {
	$dirstate_head->scan_repo_find_changed($repo);
    }

    for my $repo ($dirstate_head->repos) {
	my $mdata = $dirstate_head->{mdata};
	my $head = $mdata->{repos}{$repo}->head();
	$dirstate_head->git_walk_tree_head($repo, "", $head) unless $head eq "";
    }
}

chdir($outdir);

for my $item ($dirstate_head->items) {
    my $repo = $item->{repo};
    my $head;
    $head = $mdata_head->{repos}{$repo}->head() if ($repo ne "");
    chdir($outdir);
    next unless defined($head) or $do_new_symlinks;
    my $repopath = $item->{repopath};
    next if $repopath eq "" or $repopath eq ".";
    next unless $dirstate_head->changed(dirname($repopath));
    my $gitpath = $item->{gitpath};
    my $type = $item->{type};

    if ($type eq "dir") {
	my $dir = $repopath;

	die if $dir eq ".";
	my $dirname = $dir;
	while(!$dirstate_head->changed($dirname)) {
	    ($dir, $dirname) = ($dirname, dirname($dirname));
	}

	if (!$dirstate_head->changed($dir)) {
	    if (! (-e "$outdir/head/$dir" || -l "$outdir/head/$dir")) {
		symlink_relative($mdata_head->repo_master($mdata_head->{repos}{$repo}{name}) . "/$gitpath", "$outdir/head/$dir") or die;
	    }
	} else {
	    mkdirp("$outdir/head/$dir");
	}
    }
    if ($type eq "file") {
	my $file = $gitpath;

	if ($item->{changed} or $mdata_head->{repos}{$repo}{name} eq "") {
	    cat_file($mdata_head->repo_master($mdata_head->{repos}{$repo}{name}, 1), $head, $file, "$outdir/head/$repo$file");
	} else {
	    symlink_relative($mdata_head->repo_master($mdata_head->{repos}{$repo}{name}) . "/$file", "$outdir/head/$repo$file") or die;
	}
    }
    if ($type eq "link") {
	my $file = $gitpath;
	my $dest = `(cd '$pwd/$repo'; git cat-file blob '$head':'$file')`;
	chomp($dest);
	symlink_absolute($dest, "$outdir/head/$repo$file") or die;
    }
}

copy_or_hardlink("$pwd/README.md", "$outdir/head/") or die;
copy_or_hardlink("$pwd/Makefile", "$outdir/head/") or die;

chdir($pwd);

$do_wd &&= !(defined($apply) and defined($apply_repo) and
	     !$do_new_symlinks and !$do_new_versions);

if ($do_wd) {
    nsystem("mkdir -p $outdir/wd") or die;

    my $mdata_wd = ManifestData->new();
    my $dirstate_wd = new DirState($mdata_wd);

    for my $repo ($dirstate_wd->repos) {
	$dirstate_wd->scan_repo_find_changed($repo);
    }

    for my $repo ($dirstate_wd->repos) {
	my $mdata = $dirstate_wd->{mdata};
	my $head = $mdata->{repos}{$repo}->head;
	$dirstate_wd->git_walk_tree_head($repo, "", $head) unless $head eq "";
    }

    for my $item ($dirstate_wd->items) {
	if (-l "$pwd/" . $item->{repopath}) {
	    $item->{type} = "link";
	} elsif (!-e "$pwd/" . $item->{repopath}) {
	    $item->{type} = "none";
	} elsif (-d "$pwd/" . $item->{repopath}) {
	    $item->{type} = "dir";
	} elsif (-f "$pwd/" . $item->{repopath}) {
	    $item->{type} = "file";
	} else {
	    die;
	}
    }

    chdir($outdir);

    for my $item ($dirstate_wd->items) {
	my $repo = $item->{repo};
	my $head;
	$head = $mdata_wd->head($repo) if ($repo ne "");
	chdir($outdir);
	next unless defined($head) or $do_new_symlinks;
	my $repopath = $item->{repopath};
	next if $repopath eq "" or $repopath eq ".";
	next unless $dirstate_wd->changed(dirname($repopath));
	my $gitpath = $item->{gitpath};
	my $type = $item->{type};

	if ($type eq "dir") {
	    my $dir = $repopath;

	    die if $dir eq ".";
	    my $dirname = $dir;
	    while(!$dirstate_wd->changed($dirname)) {
		($dir, $dirname) = ($dirname, dirname($dirname));
	    }

	    if (!$dirstate_wd->changed($dir)) {
		if (! (-e "$outdir/wd/$dir" || -l "$outdir/wd/$dir")) {
		    symlink_relative($mdata_wd->repo_master($mdata_wd->{repos}{$repo}{name}) . "/$gitpath", "$outdir/wd/$dir") or die;
		}
	    } else {
		mkdirp("$outdir/wd/$dir");
	    }
	}
	if ($type eq "file") {
	    my $file = $gitpath;

	    if ($item->{changed} or $mdata_wd->{repos}{$repo}{name} eq "") {
		copy_or_hardlink("$pwd/$repo$file", "$outdir/wd/$repo$file") or die;
	    } else {
		symlink_relative($mdata_wd->repo_master($mdata_wd->{repos}{$repo}{name}) . "/$file", "$outdir/wd/$repo$file") or die;
	    }
	}
	if ($type eq "link") {
	    my $file = $gitpath;

	    copy_or_hardlink("$pwd/$repo$file", "$outdir/wd/$repo$file") or die;
	}
    }

    copy_or_hardlink("$pwd/README.md", "$outdir/wd/") or die;
    copy_or_hardlink("$pwd/Makefile", "$outdir/wd/") or die;
}

# this must come after all symbolic links have been created, so ln
# doesn't get confused about which relative path to use.
nsystem("ln -s $pwd $outdir/repo-overlay") or die;

if ($do_commit and defined($commit_message_file)) {
    chdir("$outdir/head");
    if ($do_emancipate) {
	nsystem("cd $outdir/head; git add --all .; git commit -m 'emancipation commit for $apply' " .
		(defined($commit_authordate) ? "--date '$commit_authordate' " : "") .
		(defined($commit_author) ? "--author '$commit_author' " : ""));
    } else {
	nsystem("cd $outdir/head; git commit --allow-empty -m 'COMMITTING REPO CHANGES'") if ($apply_repo eq ".repo/manifests/");
	nsystem("cd $outdir/head; git add --all .; git commit --allow-empty -F $commit_message_file " .
		(defined($commit_authordate) ? "--date '$commit_authordate' " : "") .
		(defined($commit_author) ? "--author '$commit_author' " : "")) or die;
    }
}

if (($apply_success or $do_new_versions) and !$do_emancipate) {
    for my $r ($mdata_head->repositories) {
	my $repo = $r->relpath;
	my $version_fh;
	my $head = $r->head();
	my $name = $r->name;
	my $url = $r->url;
	my $path = $r->path;

	my $comment = $r->git(log => "-1", "$head");
	$comment =~ s/^/# /msg;

	mkdirp("$outdir/head/.pipcet-ro/versions/$repo");
	open $version_fh, ">$outdir/head/.pipcet-ro/versions/$repo"."version.txt";
	print $version_fh "$repo: $head $name $url\n$comment";
	close $version_fh;
    }

    if ($do_commit) {
	nsystem("(cd $outdir/head; git add --all .; git commit -m 'versioning commit for $apply' " .
		(defined($commit_authordate) ? "--date '$commit_authordate' " : "") .
		(defined($commit_author) ? "--author '$commit_author' " : "") .
		")") or die;
    }
}

chdir($pwd);

# useful commands:
#  repo-overlay.pl -- sync repository to wd/ head/
#  diff -ur repo-overlay/ wd/|(cd repo-overlay; patch -p1) -- sync wd/ to repository (doesn't handle new/deleted files)
#  diff -urNx .git -x .repo -x out -x out-old repo-overlay/ wd/|(cd repo-overlay; patch -p1)

# perl ~/repo-tools/repo-overlay.pl --new-symlinks --new-versions --out=/home/pip/tmp-repo-overlay
# perl ~/repo-tools/repo-log.pl --just-shas|tac|while read && echo $REPLY && sh -c "perl ~/repo-tools/repo-overlay.pl $REPLY --out=/home/pip/tmp-repo-overlay"; do true; done
# perl ~/repo-tools/repo-log.pl --just-shas|tac|while read; do echo $REPLY; sh -c "perl ~/repo-tools/repo-overlay.pl $REPLY --out=/home/pip/tmp-repo-overlay"; done

# perl ~/repo-tools/repo-log.pl --just-shas --commit-dir=/home/pip/tmp-repo-overlay/commits|tac|while read; do echo "$REPLY"; sh -c "perl ~/repo-tools/repo-overlay.pl --emancipate $REPLY --out=/home/pip/tmp-repo-overlay"; sh -c "perl ~/repo-tools/repo-overlay.pl $REPLY --out=/home/pip/tmp-repo-overlay"; done

# perl ~/repo-tools/repo-log.pl --just-shas --commit-dir=/home/pip/tmp-repo-overlay/commits|tac|while read; do echo "$REPLY"; sh -c "perl ~/repo-tools/repo-overlay.pl --commit --emancipate $REPLY --out=/home/pip/tmp-repo-overlay"; sh -c "perl ~/repo-tools/repo-overlay.pl --commit $REPLY --out=/home/pip/tmp-repo-overlay"; done

# perl ~/repo-tools/repo-log.pl --additional-dir=~/tmp-repo-overlay/other-repositories/ --just-shas --commit-dir=/home/pip/tmp-repo-overlay/commits|tac|while read; do sh -c "perl ~/repo-tools/repo-overlay.pl --commit --emancipate $REPLY --out=/home/pip/tmp-repo-overlay"; sh -c "perl ~/repo-tools/repo-overlay.pl --commit $REPLY --out=/home/pip/tmp-repo-overlay"; done

exit(0);

# Local Variables:
# eval: (add-hook 'before-save-hook (quote whitespace-cleanup))
# End:
