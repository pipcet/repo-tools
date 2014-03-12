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

# like system(), but not the return value and echo command
our sub nsystem {
    my ($cmd) = @_;

    return !system($cmd);
}

our sub revparse {
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

our sub git_parents {
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

sub url {
    my ($r) = @_;

    return $r->{url};
}

sub path {
    my ($r) = @_;

    return $r->{path};
}

sub name {
    my ($r) = @_;

    return $r->{name};
}

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
	$dirstate->store_item(dirname($repopath), $item->{changed} ? {changed=>1} : {});
    }
}

sub git_walk_tree_head {
    my ($dirstate, $repo, $itempath, $head) = @_;
    my $mdata = $dirstate->{mdata};
    my $repopath = $mdata->{repos}{$repo}{path};
    my $gitpath = $mdata->get_gitpath($repo);

    die unless defined($gitpath);
    chdir($gitpath);

    my @lstree_lines = split(/\0/, `git ls-tree '$head':'$itempath' -z`);

    my @modes = map { /^(\d\d\d)(\d\d\d) ([^ ]*) ([^ \t]*)\t(.*)$/ or die; { mode=> $2, extmode => $1, path => $itempath.(($itempath eq "")?"":"/").$5 } } @lstree_lines;

    for my $m (@modes) {
	my $path = $m->{path};
	next unless $dirstate->{items}{dirname($repo.$path)}{changed};

	if ($m->{extmode} eq "120") {
	    $dirstate->store_item($repo.$path, {type=>"link"});
	} elsif ($m->{extmode} eq "100") {
	    $dirstate->store_item($repo.$path, {type=>"file"});
	} elsif ($m->{extmode} eq "040") {
	    $dirstate->store_item($repo.$path, {type=>"dir"});
	    $dirstate->git_walk_tree_head($repo, $path, $head)
		if $dirstate->{items}{$repo.$path}{changed};
	} else {
	    die "unknown mode";
	}
    }
}

sub scan_repo {
    my ($dirstate, $repo) = @_;
    my $mdata = $dirstate->{mdata};
    my $head = $mdata->get_head($repo);
    $mdata->{repos}{$repo}{head} = $head;
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

    if ($oldhead eq $newhead) {
	my %diffstat = reverse split(/\0/, `git diff $head --name-status -z`);

	for my $path (keys %diffstat) {
	    my $stat = $diffstat{$path};

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
    } else {
	my %diffstat = reverse split(/\0/, `git diff $oldhead..$newhead --name-status -z`);

	for my $path (keys %diffstat) {
	    my $stat = $diffstat{$path};

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
    }
    my $new_mdata;

    if ($repo eq ".repo/manifests/" and defined($apply)) {
	$do_rebuild_tree = 1;
	warn "rebuild tree! $apply_repo";
	my $new_mdata = ManifestData->new($apply);
	for my $repo ($new_mdata->repos) {
	    $repo->{name} = $repo->{name};
	}

	$new_mdata->{repos}{$repo}{head} = $head;

	chdir($pwd);
	chdir($repo);
	my $date = `git log -1 --pretty=tformat:\%ci $apply`;
	warn "date is $date";

	my %rset;
	for my $repo ($new_mdata->repos, $mdata->repos) {
	    $rset{$repo} = 1;
	}

	for my $repo (keys %rset) {
	    if ($new_mdata->{repos}{$repo}{name} ne
		$mdata->{repos}{$repo}{name}) {
		warn "tree rb: $repo changed from " . $mdata->{repos}{$repo}{name} . " to " . $new_mdata->{repos}{$repo}{name};
		my $head = ($new_mdata->{repos}{$repo}{name} ne "") ? $new_mdata->get_head($repo, $date) : "";
		my $diffstat =
		    git_inter_diff($mdata->{repos}{$repo}{gitpath}, $mdata->{repos}{$repo}{head},
				   $new_mdata->{repos}{$repo}{gitpath}, $head);
		if ($head ne "") {
		    $new_mdata->{repos}{$repo}{head} = $head;
		}

		for my $path (keys %$diffstat) {
		    my $stat = $diffstat->{$path};

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

		if (!$do_emancipate) {
		    nsystem("rm -rf $outdir/head/" . ($repo =~ s/\/*$//r)) unless $repo =~ /^\/*$/;
		    nsystem("rm -rf $outdir/wd/" . ($repo =~ s/\/*$//r)) unless $repo =~ /^\/*$/;
		}
		$dirstate->store_item($repo, {changed=>1});
		scan_repo($repo);
	    }
	}
    }

    $dirstate->git_walk_tree_head($repo, "", $head) unless $head eq "";

    return $new_mdata // $mdata;
}

sub scan_repo_find_changed {
    my ($dirstate, $repo) = @_;
    my $mdata = $dirstate->{mdata};
    my $head = $mdata->get_head($repo);
    $mdata->{repos}{$repo}{head} = $head;
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

    if ($oldhead eq $newhead) {
	my %diffstat = reverse split(/\0/, `git diff $head --name-status -z`);

	for my $path (keys %diffstat) {
	    my $stat = $diffstat{$path};

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
    } else {
	my %diffstat = reverse split(/\0/, `git diff $oldhead..$newhead --name-status -z`);

	for my $path (keys %diffstat) {
	    my $stat = $diffstat{$path};

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
    }
}

sub new {
    my ($class, $mdata) = @_;

    die unless $mdata;

    my $ds = {
	items => {
	    "" => { changed => 1 },
	    "." => { changed => 1}, #XXX
	},
	mdata => $mdata, };

    bless $ds, $class;

    return $ds;
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

	my $path;
	my $head;
	my $versioned_name;

	if (($path, $head, $versioned_name) = /^(.*): (.*) (.*)$/) {
	    if ($head ne "") {
		$version->{$path} = $head;
	    }
	    $mdata->{repos}{$path}{versioned_name} = $versioned_name;
	}
    }
    close $version_fh;

    return $version;
}

sub get_head {
    my ($mdata, $repo, $date, $noupdate) = @_;
    $date //= "";

    return $mdata->{repos}{$repo}{head} if exists($mdata->{repos}{$repo}{head});

    $mdata->{repos}{$repo}{repo} = $repo;

    my $gitpath = $mdata->get_gitpath($repo);

    return undef unless defined($gitpath);
    chdir($gitpath);

    my $branch = `git log -1 --reverse --pretty=oneline --until='$date'|cut -c -40`;
    chomp($branch);
    my $head;
    if ($do_new_versions) {
	$head = revparse($branch) // revparse("HEAD");
    } else {
#XXX	$head = $version{$repo} // revparse($branch) // revparse("HEAD");
    }

    die if $head eq "";

    my $oldhead = $head;
    my $newhead = $head;

    if (defined($apply)) {
	if (grep { $_ eq $head } git_parents($apply)) {
	    $newhead = $apply;
	    warn "successfully applied $apply to $repo";
	    $apply_success = 1;
	} else {
	    warn "head $head didn't match any of " . join(", ", git_parents($apply)) . " to be replaced by $apply";
	}
    }
    unless ($noupdate) {
	if (!$do_emancipate) {
	    $head = $newhead;
	}
    }

    $mdata->{repos}{$repo}{oldhead} = $oldhead;
    $mdata->{repos}{$repo}{newhead} = $newhead;

    chdir($pwd);

    return $head;
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

sub repos {
    my ($mdata) = @_;

    return sort keys %{$mdata->{repos}};
}

sub new {
    my ($class, $version, $repos_by_name_dir) = @_;
    $repos_by_name_dir //= "$outdir/repos-by-name";
    my $md = {};
    my $repos = {};

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
	my ($repopath, $name, $url, $revision) = @$r;
	$repos->{$repopath}{relpath} = $repopath;
	$repos->{$repopath}{name} = $name;
	$repos->{$repopath}{url} = $url;
	$repos->{$repopath}{revision} = $revision;
	$repos->{$repopath}{path} = "$outdir/head/$repopath";
	$repos->{$repopath}{gitpath} = "$repos_by_name_dir/$name/repo";
    }

    $repos->{".repo/repo/"} = {
	path => "$outdir/.repo/repo/",
	gitpath => "$repos_by_name_dir/.repo/repo/repo",
	name => ".repo/repo",
	relpath => ".repo/repo/",
    };

    $repos->{".repo/manifests/"} = {
	path => "$outdir/.repo/manifests/",
	gitpath => "$repos_by_name_dir/.repo/manifests/repo",
	name => ".repo/manifests",
	relpath => ".repo/manifests/",
    };

    $md->{repos} = $repos;

    bless $md, $class;

    return $md;
}

package main;

sub setup_repo_links {
    system("rm -rf $outdir/manifests/HEAD");
    my $head_mdata = ManifestData->new("HEAD");

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
    my ($gitpath_a, $rev_a, $gitpath_b, $rev_b) = @_;
    my $temp = "/home/pip/tmp"; #XXX

    nsystem("rm -rf $temp");

    mkdir($temp);

    chdir($temp);

    nsystem("git init");
    nsystem("git checkout -b empty");
    nsystem("git commit -m empty --allow-empty");
    if ($gitpath_a ne "") {
	nsystem("git fetch $gitpath_a $rev_a:a");
    } else {
	nsystem("git checkout empty; git checkout -b a");
    }
    if ($gitpath_b ne "") {
	nsystem("git fetch $gitpath_b $rev_b:b");
    } else {
	nsystem("git checkout empty; git checkout -b b");
    }

    my %diffstat = reverse split(/\0/, `git diff a b --name-status -z`);

    return \%diffstat;
}

sub get_base_version {
    my ($dir, $date) = @_;

    $date //= ""; # XXX

    chdir($dir);

    my $branch = `git log -1 --reverse --pretty=oneline --until='$date'|cut -c -40`;
    chomp($branch);
    my $head;
    if ($do_new_versions) {
	$head = revparse($branch) // revparse("HEAD");
    } else {
# XXX	$head = $version{$repo} // revparse($branch) // revparse("HEAD");
    }

    die if $head eq "";

    return $head;
}


# see comment at end of file
nsystem("rm $outdir/repo-overlay 2>/dev/null"); #XXX use as lock

nsystem("mkdir -p $outdir/head $outdir/wd") or die;
-d "$outdir/head/.git" or die;

if ($do_new_versions) {
    nsystem("rm -rf $outdir/versions/*");
    nsystem("rm -rf $outdir/head/.pipcet-ro/versions/*");
}

my %version;

# find an oldest ancestor of $head that's still a descendant of $a and $b.
sub git_find_descendant {
    my ($head, $a, $b) = @_;

    my $d;

    for my $p (git_parents($head)) {
	if (nsystem("git merge-base --is-ancestor $p $a") and
	    nsystem("git merge-base --is-ancestor $p $b")) {
	    return git_find_descendant($p, $a, $b);
	}
    }

    return $head;
}

sub check_apply {
    my ($apply, $apply_repo) = @_;

    die if $apply eq "";

    my %version = %{read_versions({})};

    my $repo = $apply_repo;
    if (chdir($repo)) {
	if (!defined(revparse($apply))) {
	    die "commit $apply isn't in $repo.";
	}
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
		my $d = git_find_descendant("HEAD", $apply, $version{$repo});
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
}

if (defined($apply) and defined($apply_repo)) {
    check_apply($apply, $apply_repo);
}

chdir($pwd);

my $mdata_head = ManifestData->new(get_base_version("$pwd/.repo/manifests"));
my $dirstate_head = new DirState($mdata_head);
my $mdata_wd = ManifestData->new(get_base_version("$pwd/.repo/manifests"));
my $dirstate_wd = new DirState($mdata_wd);

unless ($do_new_symlinks) {
    chdir("$outdir/head");
    my @dirs = split(/\0/, `find -name .git -prune -o -type d -print0`);

    for my $dir (@dirs) {
	$dir =~ s/^\.\///;
	$dir =~ s/\/*$//;
	$dirstate_head->store_item($dir, {changed=>1});
    }

    my @files = split(/\0/, `find -name .git -prune -o -type f -print0`);

    for my $file (@files) {
	$file =~ s/^\.\///;
	$file =~ s/\/*$//;
	$dirstate_head->store_item($file, {changed=>1});
    }

    chdir($pwd);
}

%version = %{$mdata_head->read_versions()};

for my $repo ($mdata_head->repos) {
    $mdata_head->{repos}{$repo}{name} = $mdata_head->{repos}{$repo}{name};
}

for my $repo ($mdata_wd->repos) {
    $mdata_wd->{repos}{$repo}{name} = $mdata_wd->{repos}{$repo}{name};
}

if (defined($apply_repo_name) and !defined($apply_repo)) {
    for my $repo (keys %version) {
	if ($mdata_head->{repos}{$repo}{name} eq $apply_repo_name) {
	    $apply_repo = $repo;
	    warn "found repo to apply to: $apply_repo for $apply_repo_name";
	    last;
	}
    }

    die "couldn't find repo $apply_repo_name, aborting" unless defined($apply_repo_name);;

    check_apply($apply, $apply_repo);
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
    #XXX
    $mdata_head->{repos}{$apply_repo}{name} = $mdata_head->{repos}{$apply_repo}{versioned_name};
}

if ($do_new_symlinks) {
    setup_repo_links();
}

if (defined($apply) and defined($apply_repo) and !defined($apply_repo_name)) {
    my $manifest = $apply_last_manifest // "HEAD";
    my $backrepos = repos($manifest);
    my $name = $backrepos->{$apply_repo}{name};

    unless (defined($name)) {
	warn "cannot resolve repo $apply_repo (manifest $manifest)";
	exit(0);
    }

    $apply_repo_name = $name;
    $mdata_head->{repos}{$apply_repo} = $backrepos->{$apply_repo};
    $mdata_head->{repos}{$apply_repo}{name} = $name;

    warn "resolved $apply_repo to $name\n";

    check_apply($apply, $apply_repo);
}

if (defined($apply) and defined($apply_repo) and
    !$do_new_symlinks and !$do_new_versions) {
    for my $repo ($dirstate_head->repos) {
	$dirstate_head->store_item($repo, {changed=>1}); # XXX for nested repositories
    }

    for my $repo ($dirstate_head->repos) {
	$dirstate_head->scan_repo_find_changed($repo);
    }

    for my $repo ($dirstate_head->repos) {
	my $mdata = $dirstate_head->{mdata};
	my $head = $mdata->{repos}{$repo}{head};
	$dirstate_head->git_walk_tree_head($repo, "", $head) unless $head eq "";
    }
} else {
    for my $repo ($dirstate_head->repos) {
	$dirstate_head->store_item($repo, {changed=>1}); # XXX for nested repositories
    }

    for my $repo ($dirstate_head->repos) {
	$dirstate_head->scan_repo_find_changed($repo);
    }

    for my $repo ($dirstate_head->repos) {
	my $mdata = $dirstate_head->{mdata};
	my $head = $mdata->{repos}{$repo}{head};
	$dirstate_head->git_walk_tree_head($repo, "", $head) unless $head eq "";
    }

    for my $repo ($dirstate_wd->repos) {
	$dirstate_wd->store_item($repo, {changed => 1}); # XXX for nested repositories
    }

    for my $repo ($dirstate_wd->repos) {
	$dirstate_wd->scan_repo_find_changed($repo);
    }

    for my $repo ($dirstate_wd->repos) {
	my $mdata = $dirstate_wd->{mdata};
	my $head = $mdata->{repos}{$repo}{head};
	$dirstate_wd->git_walk_tree_head($repo, "", $head) unless $head eq "";
    }
}

chdir($pwd);

for my $item ($dirstate_wd->items) {
    if (-l $item->{repopath}) {
	$item->{type} = "link";
    } elsif (!-e $item->{repopath}) {
	$item->{type} = "none";
    } elsif (-d $item->{repopath}) {
	$item->{type} = "dir";
    } elsif (-f $item->{repopath}) {
	$item->{type} = "file";
    } else {
	die;
    }
}

chdir($outdir);

for my $item ($dirstate_head->items) {
    my $repo = $item->{repo};
    my $head;
    $head = $mdata_head->get_head($repo) if ($repo ne "");
    next unless defined($head) or $do_new_symlinks;
    my $repopath = $item->{repopath};
    next if $repopath eq "" or $repopath eq ".";
    next unless $dirstate_head->{items}{dirname($repopath)}{changed};
    my $gitpath = $item->{gitpath};
    my $type = $item->{type};

    if ($type eq "dir") {
	my $dir = $repopath;

	die if $dir eq ".";
	my $dirname = $dir;
	while(!$dirstate_head->{items}{$dirname}{changed}) {
	    ($dir, $dirname) = ($dirname, dirname($dirname));
	}

	if (!$dirstate_head->{items}{$dir}{changed}) {
	    if (! (-e "head/$dir" || -l "head/$dir")) {
		symlink_relative($mdata_head->repo_master($mdata_head->{repos}{$repo}{name}) . "/$gitpath", "head/$dir") or die;
	    }
	} else {
	    mkdirp("head/$dir")
	}
    }
    if ($type eq "file") {
	my $file = $gitpath;

	if ($item->{changed} or $mdata_head->{repos}{$repo}{name} eq "") {
	    cat_file($mdata_head->repo_master($mdata_head->{repos}{$repo}{name}, 1), $head, $file, "head/$repo$file");
	} else {
	    symlink_relative($mdata_head->repo_master($mdata_head->{repos}{$repo}{name}) . "/$file", "head/$repo$file") or die;
	}
    }
    if ($type eq "link") {
	my $file = $gitpath;
	my $dest = `(cd $pwd/$repo; git cat-file blob '$head':'$file')`;
	chomp($dest);
	symlink_absolute($dest, "head/$repo$file") or die;
    }
}

for my $item ($dirstate_wd->items) {
    my $repo = $item->{repo};
    my $head;
    $head = $mdata_wd->get_head($repo) if ($repo ne "");
    next unless defined($head) or $do_new_symlinks;
    my $repopath = $item->{repopath};
    next if $repopath eq "" or $repopath eq ".";
    next unless $dirstate_wd->{items}{dirname($repopath)}{changed};
    my $gitpath = $item->{gitpath};
    my $type = $item->{type};

    if ($type eq "dir") {
	my $dir = $repopath;

	die if $dir eq ".";
	my $dirname = $dir;
	while(!$dirstate_wd->{items}{$dirname}{changed}) {
	    ($dir, $dirname) = ($dirname, dirname($dirname));
	}

	if (!$dirstate_wd->{items}{$dir}{changed}) {
	    if (! (-e "wd/$dir" || -l "wd/$dir")) {
		symlink_relative($mdata_wd->repo_master($mdata_wd->{repos}{$repo}{name}) . "/$gitpath", "wd/$dir") or die;
	    }
	} else {
	    mkdirp("wd/$dir")
	}
    }
    if ($type eq "file") {
	my $file = $gitpath;

	if ($item->{changed} or $mdata_wd->{repos}{$repo}{name} eq "") {
	    copy_or_hardlink("$pwd/$repo$file", "wd/$repo$file") or die;
	} else {
	    symlink_relative($mdata_wd->repo_master($mdata_wd->{repos}{$repo}{name}) . "/$file", "wd/$repo$file") or die;
	}
    }
    if ($type eq "link") {
	my $file = $gitpath;

	copy_or_hardlink("$pwd/$repo$file", "wd/$repo$file") or die;
    }
}

copy_or_hardlink("$pwd/README.md", "$outdir/head/") or die;
copy_or_hardlink("$pwd/README.md", "$outdir/wd/") or die;
copy_or_hardlink("$pwd/Makefile", "$outdir/head/") or die;
copy_or_hardlink("$pwd/Makefile", "$outdir/wd/") or die;

# this must come after all symbolic links have been created, so ln
# doesn't get confused about which relative path to use.
nsystem("ln -s $pwd $outdir/repo-overlay") or die;

if ($do_commit and defined($commit_message_file)) {
    chdir("$outdir/head");
    if ($do_emancipate) {
	nsystem("git add --all .; git commit -m 'emancipation commit for $apply' " .
		(defined($commit_authordate) ? "--date '$commit_authordate' " : "") .
		(defined($commit_author) ? "--author '$commit_author' " : ""));
    } else {
	nsystem("git commit --allow-empty -m 'COMMITTING REPO CHANGES'") if ($apply_repo eq ".repo/manifests/");
	nsystem("git add --all .; git commit --allow-empty -F $commit_message_file " .
		(defined($commit_authordate) ? "--date '$commit_authordate' " : "") .
		(defined($commit_author) ? "--author '$commit_author' " : "")) or die;
    }
}

if (($apply_success or $do_new_versions) and !$do_emancipate) {
    for my $repo ($mdata_head->repos) {
	my $version_fh;

	mkdirp("$outdir/head/.pipcet-ro/versions/$repo");
	open $version_fh, ">$outdir/head/.pipcet-ro/versions/$repo"."version.txt";
	print $version_fh "$repo: ".$mdata_head->{repos}{$repo}{head}." ".$mdata_head->{repos}{$repo}{name}."\n";
	close $version_fh;
    }

    if ($do_commit) {
	nsystem("git add --all .; git commit -m 'versioning commit for $apply' " .
		(defined($commit_authordate) ? "--date '$commit_authordate' " : "") .
		(defined($commit_author) ? "--author '$commit_author' " : "")) or die;
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
