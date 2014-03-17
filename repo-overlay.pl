#!/usr/bin/perl
use strict;
no warnings "experimental::lexical_subs";
use feature 'lexical_subs';

use File::Basename qw(dirname);
use File::Path qw(make_path);
use Getopt::Long qw(:config auto_version auto_help);
use File::PathConvert qw(abs2rel rel2abs);
use File::Copy::Recursive qw(fcopy);
use Carp::Always;

use Git::Raw;

my $do_new_versions;
my $do_new_symlinks;
my $do_print_range;
my $do_hardlink;
my $do_commit;
my $do_rebuild_tree;
my $do_emancipate;
my $do_de_emancipate;
my $do_wd = 1;
my $do_head = 1;
my $do_head_old = 1;
my $do_head_new = 1;

my $apply;
my $apply_repo;
my $apply_success;
my $apply_repo_name;
my $apply_last_manifest;

my $outdir;
my $indir = ".";

my $commit_message_file;

my $commit_commitdate;
my $commit_committer;
my $commit_authordate;
my $commit_author;

my $date;

GetOptions(
    "hardlink!" => \$do_hardlink,
    "out=s" => \$outdir,
    "in=s" => \$indir,
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

    #warn "running $cmd";

    return !system($cmd);
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

our sub xdirname {
    return dirname(@_) =~ s/^\.$//r;
}

our sub mkdirp {
    my ($dir) = @_;

    make_path($dir);

    return 1;
}

our sub symlink_relative {
    my ($src, $dst) = @_;
    my $noprefix;
    if (begins_with($src, "$pwd/", \$noprefix)) {
	$src = "$outdir/repo-overlay/$noprefix";
    }
    my $relsrc = abs2rel($src, xdirname($dst));

    mkdirp(xdirname($dst)) or die "cannot make symlink $dst -> $relsrc";

    symlink($relsrc, $dst) or die "cannot make symlink $dst -> $relsrc";
}

our sub symlink_absolute {
    my ($src, $dst) = @_;

    mkdirp(xdirname($dst)) or die;

    symlink($src, $dst) or die "cannot make symlink $dst -> $src";
}

our sub copy_or_hardlink {
    my ($src, $dst) = @_;

    return fcopy($src, $dst);
}

our sub cat_file {
    my ($master, $branch, $file, $dst) = @_;

    mkdirp(xdirname($dst)) or die;

    if ($branch ne "") {
	nsystem("cd '$master'; git cat-file blob '$branch':'$file' > $dst") or die;
    } else {
	nsystem("cat '$master'/'$file' > $dst") or die;
    }

    return 1;
}

package Repository;

sub url {
    my ($r) = @_;

    return $r->{url};
}

sub relpath {
    my ($r) = @_;

    return $r->{relpath};
}

sub name {
    my ($r) = @_;

    return $r->{name};
}

sub master {
    my ($r) = @_;
    my $name = $r->name;

    return $r->{master} if exists($r->{master});

    if ($name eq "") {
	my $master = "$pwd";

	return $master;
    }

    my $master = readlink("$outdir/repos-by-name/$name/repo");

    $master =~ s/\/$//;

    die "no master for $name" unless(defined($master));

    $r->{master} = $master;

    return $master;
}

package Repository::Git;
use parent -norequire, "Repository";

sub gitpath {
    my ($r) = @_;
    my $gitpath = $r->{gitpath};

    if ($gitpath eq "" or ! -e $gitpath) {
	my $url = $r->url;

	if (!($url=~/\/\//)) {
	    # XXX why is this strange fix needed?
	    $url = "https://github.com/" . $r->name;
	}

	warn "no repository for " . $r->name . " url $url";

	#system("git clone $url $outdir/other-repositories/" . $r->name);
	return undef;
    }

    return $gitpath;
}

sub version {
    my ($r) = @_;

    return $r->{version};
}

sub revparse {
    my ($r, $head) = @_;
    my $last = $r->git("rev-parse" => $head);
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
	# XXX test this
	if ($r->git_ancestor($p, $a) and
	    $r->git_ancestor($p, $b)) {
	    return $r->git_find_descendant($p, $a, $b);
	}
    }

    return $head;
}

sub git_find_missing_link {
    my ($r, $a, $b) = @_;

    my $d;

    for my $p ($r->git_parents($b)) {
	if (grep { $_ eq $a } $r->git_parents($p)) {
	    return $p;
	}
    }

    return undef;
}

sub head {
    my ($r) = @_;

    return $r->{head} if exists($r->{head});

    my $repo = $r->{relpath};
    my $date = $r->{date} // "";

    my $branch = $r->git(log => "-1", "--first-parent", "--reverse", "--pretty=oneline", "--until=$date");
    $branch = substr($branch, 0, 40);

    my $head;
    if ($do_new_versions) {
	$head = $r->revparse($branch) // $r->revparse("HEAD");
    } else {
	$head = $r->version // die("$repo") // $r->revparse($branch) // $r->revparse("HEAD");
    }

    die if $head eq "";

    my $oldhead = $head;
    my $newhead = $head;

    $r->{oldhead} = $oldhead;
    $r->{newhead} = $newhead;
    $r->{head} = $head;

    return $head;
}

sub gitrawtree {
    my ($r) = @_;

    return $r->{gitrawtree} if exists($r->{gitrawtree});

    my $raw = $r->gitrepository;
    my $head = $raw->lookup($r->head);

    $head = $head->target while $head->isa("Git::Raw::Reference");

    my $tree = $head->tree;

    return ($r->{gitrawtree} = $tree);
}

sub gitrepository {
    my ($r) = @_;

    return $r->{gitrepository} if exists($r->{gitrepository});

    return ($r->{gitrepository} = Git::Raw::Repository->open($r->gitpath));
}

sub git {
    my ($r, @args) = @_;

    die if grep { /\'/ } @args;

    my $path = $r->gitpath;
    my $cmd = "cd '$path'; git " . join(" ", map { "'$_'" } @args) . " 2>/dev/null";

    my $output = `$cmd`;

    chomp($output);

    return $output;
}

sub gitp {
    my ($r, @args) = @_;

    $r->git(@args);

    return !($?>>8);
}

sub gitz {
    my ($r, @args) = @_;

    return split(/\0/, $r->git(@args, "-z"));
}

sub git_ancestor {
    my ($r, $a, $b) = @_;

    return $r->gitp("merge-base", "--is-ancestor", $a, $b);
}

sub new {
    my ($class, $path, $name, $url, $gitpath, $date, $version) = @_;
    my $r = bless {}, $class;

    $r->{relpath} = $path;
    $r->{name} = $name;
    $r->{url} = $url;
    $r->{gitpath} = $gitpath;
    $r->{date} = $date;
    $r->{version} = $version;

    return $r;
}

package Repository::Git::Head;
use parent -norequire, "Repository::Git";

use File::Basename qw(dirname);
use File::Path qw(make_path);
use Getopt::Long qw(:config auto_version auto_help);
use File::PathConvert qw(abs2rel);
use File::Copy::Recursive qw(fcopy);
use Carp::Always;

sub find_changed {
    my ($r, $dirstate) = @_;
    my $mdata = $dirstate->{mdata};
    my $repo = $r->relpath;
    my $head = $r->head;
    my $oldhead = $r->{oldhead};
    my $newhead = $r->{newhead};

    $dirstate->store_item($repo, { type=>"dir" });
    if (begins_with($r->master, "$pwd/")) {
	$dirstate->store_item(xdirname($repo), {type=>"dir"});
    } else {
	$dirstate->store_item(xdirname($repo), {type=>"dir", changed=>1});
    }

    if (!defined($head)) {
	$dirstate->store_item($repo, {changed=>1});
	return;
    }

    my %diffstat = reverse $r->gitz(diff => "$head", "--name-status");

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
	my %diffstat = reverse $r->gitz(diff => "$oldhead..$newhead", "--name-status");

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

sub find_siblings_and_types_rec {
    my ($r, $dirstate, $tree, $path) = @_;
    my $repo = $r->relpath;

    for my $entry (@{$tree->entries}) {
	my $filemode = $entry->filemode;
	my $name = $entry->name;

	my $extmode = substr($filemode, 0, 3);

	if ($extmode eq "120") {
	    $dirstate->store_item($repo.$path.$name, {type=>"link"});
	} elsif ($extmode eq "100") {
	    $dirstate->store_item($repo.$path.$name, {type=>"file"});
	} elsif ($extmode eq "040") {
	    $dirstate->store_item($repo.$path.$name, {type=>"dir"});
	    $r->find_siblings_and_types_rec($dirstate, $entry->object, "$path$name/")
		if $dirstate->changed($repo.$path);
	} else {
	    die "unknown mode";
	}
    }
}

sub find_siblings_and_types {
    my ($r, $dirstate, $path) = @_;
    my $repo = $r->relpath;
    my $head = $r->head;
    my $raw = $r->gitrepository;

    my $tree = $raw->head->tree;

    die $tree unless $tree->isa("Git::Raw::Tree");

    $r->find_siblings_and_types_rec($dirstate, $tree, "");
}

sub create_file {
    my ($r, $file, $dst) = @_;

    cat_file($r->master, $r->head, $file, $dst);
}

sub create_link {
    my ($r, $file, $dst) = @_;
    my $head = $r->head;

    my $dest = $r->git("cat-file" => "blob" => "$head:$file");
    chomp($dest);
    symlink_absolute($dest, $dst) or die;
}

package Repository::Git::Head::New;
use parent -norequire, "Repository::Git::Head";

sub head {
    my ($r) = @_;

    return $r->{head} if exists($r->{head});

    my $head = $r->SUPER::head;
    my $repo = $r->{relpath};

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

    return $head;
}


package Repository::Git::WD;
use parent -norequire, "Repository::Git";

use File::Basename qw(dirname);
use File::Path qw(make_path);
use Getopt::Long qw(:config auto_version auto_help);
use File::PathConvert qw(abs2rel rel2abs);
use File::Copy::Recursive qw(fcopy);
use Carp::Always;

sub find_siblings_and_types {
    my ($r, $dirstate, $path) = @_;
    $path //= $r->relpath;
    my $mdata = $dirstate->{mdata};

    my $dh;
    opendir $dh, "$pwd/$path" or die;
    my @files = readdir $dh;
    close $dh;

    @files = grep { $_ ne "." and $_ ne ".." and $_ ne ".git" and $_ ne ".repo" } @files;
    @files = map { "$path$_" } @files;
    @files = grep { $_ ne "out" } @files;

    for my $file (@files) {
	next if $mdata->{repos}{$file . "/"};
	if (-l "$pwd/$file") {
	    $dirstate->store_item($file, {type=>"link"});
	} elsif (!-e "$pwd/$file") {
	    $dirstate->store_item($file, {type=>"none"});
	} elsif (-d "$pwd/$file") {
	    if (!-d "$pwd/$file/.git") {
		$dirstate->store_item($file, {type=>"dir"});
		$r->find_siblings_and_types($dirstate, "$file/")
		    if $dirstate->changed($file);
	    }
	} elsif (-f "$pwd/$file") {
	    $dirstate->store_item($file, {type=>"file"});
	} else {
	    die;
	}
    }
}

sub find_changed {
    my ($r, $dirstate) = @_;
    my $mdata = $dirstate->{mdata};
    my $repo = $r->relpath;
    my $head = $r->head;
    my $oldhead = $r->{oldhead};
    my $newhead = $r->{newhead};

    $dirstate->store_item($repo, { type=>"dir" });
    if (begins_with($r->master, "$pwd/")) {
	$dirstate->store_item(xdirname($repo), {type=>"dir"});
    } else {
	$dirstate->store_item(xdirname($repo), {type=>"dir", changed=>1});
    }

    if (!defined($head)) {
	$dirstate->store_item($repo, {changed=>1});
	return;
    }

    my %diffstat = reverse $r->gitz(diff => "$head", "--name-status");

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
	my %diffstat = reverse $r->gitz(diff => "$oldhead..$newhead", "--name-status");

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

sub create_file {
    my ($r, $file, $dst) = @_;
    my $repo = $r->relpath;

    copy_or_hardlink("$pwd/$repo$file", $dst) or die;
}

sub create_link {
    my ($r, $file, $dst) = @_;
    my $repo = $r->relpath;

    copy_or_hardlink("$pwd/$repo$file", $dst) or die;
}

package Repository::WD;
use parent -norequire, "Repository";

sub create_file {
    my ($r, $file, $dst) = @_;
    my $pwd = $r->{pwd};
    my $repo = $r->relpath;

    copy_or_hardlink("$pwd/$repo$file", $dst) or die;
}

sub create_link {
    my ($r, $file, $dst) = @_;
    my $pwd = $r->{pwd};
    my $repo = $r->relpath;

    copy_or_hardlink("$pwd/$repo$file", $dst) or die;
}

sub find_changed {
    my ($r, $dirstate, $path) = @_;
    my $pwd = $r->{pwd};

    my $dh;
    opendir $dh, "$pwd/$path" or die;
    my @files = readdir $dh;
    close $dh;

    @files = grep { $_ ne "." and $_ ne ".." and $_ ne ".git" and $_ ne ".repo" } @files;
    @files = map { "$path$_" } @files;
    @files = grep { $_ ne "out" } @files;

    for my $file (@files) {
	next if ($dirstate->mdata->{repos}{$file . "/"});
	$dirstate->store_item($file, {changed => 1})
	    unless -d "$pwd/$file";
	if (-d "$pwd/$file" and !-d "$pwd/$file/.git") {
	    $r->find_changed($dirstate, "$file/");
	}
    }
}

sub find_siblings_and_types {
    my ($r, $dirstate, $path) = @_;
    my $pwd = $r->{pwd};

    my $dh;
    opendir $dh, "$pwd/$path" or die;
    my @files = readdir $dh;
    close $dh;

    @files = grep { $_ ne "." and $_ ne ".." and $_ ne ".git" and $_ ne ".repo" } @files;
    @files = map { "$path$_" } @files;
    @files = grep { $_ ne "out" } @files;

    for my $file (@files) {
	next if ($dirstate->mdata->{repos}{$file . "/"});
	if (-l "$pwd/$file") {
	    $dirstate->store_item($file, {type=>"link"});
	} elsif (!-e "$pwd/$file") {
	    $dirstate->store_item($file, {type=>"none"});
	} elsif (-d "$pwd/$file") {
	    if (!-d "$pwd/$file/.git") {
		$dirstate->store_item($file, {type=>"dir"});
		$r->find_siblings_and_types($dirstate, "$file/")
		    if $dirstate->changed($file);
	    }
	} elsif (-f "$pwd/$file") {
	    $dirstate->store_item($file, {type=>"file"});
	} else {
	    die;
	}
    }
}

sub new {
    my ($class, $pwd) = @_;
    my $r = bless {}, $class;

    $r->{pwd} = $pwd;

    return $r;
}

package Item;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Getopt::Long qw(:config auto_version auto_help);
use File::PathConvert qw(abs2rel);
use File::Copy::Recursive qw(fcopy);
use Carp::Always;

sub create {
    my ($item, $dirstate, $outdir) = @_;

    my $gitpath = $item->{gitpath};
    my $repo = $item->{repo};
    my $r = $item->{r};

    return unless $r or $do_new_symlinks;
    my $repopath = $item->{repopath};
    return unless $dirstate->directory_changed($repopath);
    my $type = $item->{type};

    if ($type eq "dir") {
	my $dir = $repopath;

	warn if $dir eq ".";
	my $dirname = $dir;
	while (!$dirstate->changed($dirname)) {
	    ($dir, $dirname) = ($dirname, xdirname($dirname));
	}

	if (!$dirstate->changed($dir)) {
	    if (! (-e "$outdir/$dir" || -l "$outdir/$dir")) {
		symlink_relative("$pwd/$dir", "$outdir/$dir") or die;
	    }
	} else {
	    mkdirp("$outdir/$dir");
	}
    } elsif ($type eq "file") {
	my $file = $gitpath;

	if ($item->{changed}) {
	    $r->create_file($file, "$outdir/$repo$file");
	} else {
	    symlink_relative($r->master . "/$file", "$outdir/$repo$file") or die;
	}
    } elsif ($type eq "link") {
	my $file = $gitpath;
	$r->create_link($file, "$outdir/$repo$file");
    }
}

sub type {
    my ($item) = @_;

    return $item->{type};
}

package DirState;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Getopt::Long qw(:config auto_version auto_help);
use File::PathConvert qw(abs2rel);
use File::Copy::Recursive qw(fcopy);
use Carp::Always;

sub mdata {
    my ($dirstate) = @_;

    return $dirstate->{mdata};
}

sub items {
    my ($dirstate) = @_;

    return map { $dirstate->{items}{$_}} sort keys %{$dirstate->{items}};
}

sub directory_changed {
    my ($dirstate, $item) = @_;

    my $dir = xdirname($item);

    return $dirstate->{items}{$dir} && $dirstate->{items}{$dir}{changed};
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
    my ($dirstate, $repopath, $item) = @_;
    my $mdata = $dirstate->{mdata};
    $repopath =~ s/\/*$//;

    my $repo = $repopath;
    $repo =~ s/\/*$/\//;
    while (1) {
	if (my $r = $mdata->{repos}{$repo}) {
	    $item->{repo} = $repo;
	    $item->{r} = $r;
	    last;
	}
	$repo = xdirname($repo) . "/";
    }

    $item->{repo} = $repo = undef unless ($item->{r});

    die if $repopath =~ /\/\//;

    if (defined($item->{r}) and !defined($item->{masterpath})) {
	my $master = $item->{r}->master;
	my $masterpath = $master . prefix($repopath, $item->{repo} =~ s/\/$//r);

	$item->{masterpath} = $masterpath;
	$item->{master} = $master;

	#warn "using default masterpath $masterpath ($master) for $repopath";
    }

    $item->{masterpath} =~ s/\/*$//;
    die if $item->{masterpath} =~ /\/\//;
    my $masterpath = $item->{masterpath};

    $item->{changed} = 1 if $repopath eq "";

    $item->{gitpath} = prefix($repopath, $item->{repo} =~ s/\/*$//r);
    $item->{gitpath} =~ s/^\/*//;
    $item->{gitpath} =~ s/\/*$//;

    $item->{repopath} = $repopath;

    my $olditem = ($dirstate->{items}{$repopath} //= bless {}, "Item");

    for my $key (keys %$item) {
	$olditem->{$key} = $item->{$key};
    }

    return if $repopath eq "";

    my $dir = xdirname($repopath);
    if (!$dirstate->{items}{$dir} ||
	$item->{changed} > $dirstate->changed($dir)) {
	$dirstate->store_item($dir, $item->{changed} ? {changed=>1, type=>"dir"} : {type=>"dir"});
    }
}

sub create_directory {
    my ($dirstate, $outdir) = @_;

    for my $item ($dirstate->items) {
	$item->create($dirstate, $outdir);
    }
}

sub snapshot {
    my ($dirstate, $outdir, @repos) = @_;

    nsystem("rm -rf $outdir/*") unless (@repos);
    nsystem("rm -rf $outdir/.repo") unless (@repos);
    nsystem("mkdir -p $outdir") or die;

    @repos = $dirstate->repos unless (@repos);

    for my $repo (@repos) {
	my $mdata = $dirstate->mdata;
	my $r = $mdata->repositories($repo);
	$r->find_changed($dirstate);
    }

    for my $repo (@repos) {
	my $mdata = $dirstate->mdata;
	my $r = $mdata->repositories($repo);
	$r->find_siblings_and_types($dirstate);
    }

    $dirstate->create_directory("$outdir");
}

sub new {
    my ($class, $mdata) = @_;

    die unless $mdata;

    my $dirstate = {
	items => {
	    "" => bless({ changed => 1 }, "Item"),
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

sub read_version {
    my ($mdata, $repo) = @_;

    return $mdata->{version}{$repo} if $mdata->{version} and defined($mdata->{version}{$repo});

    my $version = { };
    my $version_fh;

    # XXX
    if (-d "$outdir/head/.pipcet-ro/versions/$repo") {
	open $version_fh, "cat /dev/null `find $outdir/head/.pipcet-ro/versions/'$repo' -name version.txt`|";
	while (<$version_fh>) {
	    chomp;
	    next if /^#/;

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
    }

    return $version->{$repo};
}

sub read_versions {
    my ($mdata) = @_;

    return $mdata->{version} if $mdata->{version};

    my $version = { };
    my $version_fh;

    # XXX
    if (-d "$outdir/head/.pipcet-ro/versions") {
	open $version_fh, "cat /dev/null `find $outdir/head/.pipcet-ro/versions/ -name version.txt`|";
	while (<$version_fh>) {
	    chomp;
	    next if /^#/;

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
    }

    $mdata->{version} = $version;

    return $version;
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

sub new_repository {
    my ($mdata, $repopath, @args) = @_;

    $mdata->{repos}{$repopath} =
	$mdata->repository_class->new($repopath, @args);
}

package ManifestData::Head;
use parent -norequire, "ManifestData";

sub repository_class {
    return "Repository::Git::Head";
}

sub new {
    my ($class, $version, $date) = @_;
    my $repos_by_name_dir = "$outdir/repos-by-name";
    my $mdata = bless {}, $class;

    $mdata->read_versions;

    $mdata->{repos_by_name_dir} = $repos_by_name_dir;
    $mdata->{date} = $date;

    if (!defined($version)) {
	if (defined($date)) {
	    $version = `cd $pwd/.repo/manifests; git log -1 --first-parent --pretty=tformat:'\%H' --until='$date'`;
	    chomp($version);
	}
    }

    my @res;
    if (defined($version)) {
	die if $version eq "";
	if (! -d "$outdir/manifests/$version/manifests") {
	    nsystem("mkdir -p $outdir/manifests/$version/manifests") or die;
	    nsystem("cp -a $pwd/.repo/local_manifests $outdir/manifests/$version/") or die;
	    nsystem("git clone $pwd/.repo/manifests $outdir/manifests/$version/manifests") or die;
	    nsystem("(cd $outdir/manifests/$version/manifests && git checkout $version && cp -a .git ../manifests.git && ln -s manifests/default.xml ../manifest.xml && git config remote.origin.url git://github.com/Quarx2k/android.git)") or die;
	    nsystem("cd $pwd; python $pwd/.repo/repo/main.py --wrapper-version=1.21 --repo-dir=$outdir/manifests/$version -- list --url > $outdir/manifests/$version/output") or die;
	}

	@res = `cat $outdir/manifests/$version/output`;
    } else {
	@res = `cd $pwd; python $pwd/.repo/repo/main.py --wrapper-version=1.21 --repo-dir=$pwd/.repo -- list --url`;
    }

    map { $_ = [split(/ : /)] } @res;

    map { $_->[0] =~ s/\/*$/\//; } @res;

    for my $r (@res) {
	my ($repopath, $name, $url, $branchref) = @$r;
	$mdata->new_repository($repopath, $name, $url,
			       "$repos_by_name_dir/$name/repo",
			       $date, $mdata->{version}{$repopath});
    }

    $mdata->new_repository(".repo/repo/", ".repo/repo", "",
			   "$repos_by_name_dir/.repo/repo/repo",
			   $date, $mdata->{version}{".repo/repo/"});

    $mdata->new_repository(".repo/manifests/", ".repo/manifests", "",
			   "$repos_by_name_dir/.repo/manifests/repo",
			   $date, $mdata->{version}{".repo/manifests/"});

    $mdata->{repos}{"/"} = new Repository::WD($pwd);

    return $mdata;
}

package ManifestData::Head::New;
use parent -norequire, "ManifestData::Head";

sub repository_class {
    return "Repository::Git::Head::New";
}

package ManifestData::WD;
use parent -norequire, "ManifestData";

sub repository_class {
    return "Repository::Git::WD";
}

sub new {
    my ($class, $version, $date) = @_;
    my $repos_by_name_dir = "$outdir/repos-by-name";
    my $mdata = bless {}, $class;

    $mdata->{repos_by_name_dir} = $repos_by_name_dir;
    $mdata->{date} = $date;
    $mdata->read_versions;

    if (!defined($version)) {
	if (defined($date)) {
	    $version = `cd $pwd/.repo/manifests; git log -1 --first-parent --pretty=tformat:'\%H' --until='$date'`;
	    chomp($version);
	}
    }

    my @res;
    if (defined($version)) {
	die if $version eq "";
	if (! -d "$outdir/manifests/$version/manifests") {
	    nsystem("mkdir -p $outdir/manifests/$version/manifests") or die;
	    nsystem("cp -a $pwd/.repo/local_manifests $outdir/manifests/$version/") or die;
	    nsystem("git clone $pwd/.repo/manifests $outdir/manifests/$version/manifests") or die;
	    nsystem("(cd $outdir/manifests/$version/manifests && git checkout $version && cp -a .git ../manifests.git && ln -s manifests/default.xml ../manifest.xml && git config remote.origin.url git://github.com/Quarx2k/android.git)") or die;
	    nsystem("cd $pwd; python $pwd/.repo/repo/main.py --wrapper-version=1.21 --repo-dir=$outdir/manifests/$version -- list --url` > $outdir/manifests/$version/output")
	}

	@res = `cat $outdir/manifests/$version/output`;
    } else {
	@res = `cd $pwd; python $pwd/.repo/repo/main.py --wrapper-version=1.21 --repo-dir=$pwd/.repo -- list --url`;
    }

    map { $_ = [split(/ : /)] } @res;

    map { $_->[0] =~ s/\/*$/\//; } @res;

    for my $r (@res) {
	my ($repopath, $name, $url, $branchref) = @$r;
	$mdata->new_repository($repopath, $name, $url,
			       "$repos_by_name_dir/$name/repo",
			       $date, $mdata->{version}{$repopath});
    }

    $mdata->new_repository(".repo/repo/", ".repo/repo", "",
			   "$repos_by_name_dir/.repo/repo/repo",
			   $date, $mdata->{version}{".repo/repo/"});

    $mdata->new_repository(".repo/manifests/", ".repo/manifests", "",
			   "$repos_by_name_dir/.repo/manifests/repo",
			   $date, $mdata->{version}{".repo/manifests/"});

    $mdata->{repos}{"/"} = new Repository::WD($pwd);

    return $mdata;
}

package main;

sub setup_repo_links {
    my $head_mdata = ManifestData::Head::New->new();

    system("rm -rf $outdir/repos-by-name");
    for my $r ($head_mdata->repositories) {
	my $name = $r->name;
	next if $name eq "";

	my $linkdir = "$outdir/repos-by-name/" . $name . "/";

	mkdirp($linkdir);
	symlink_absolute("$pwd/" . $r->relpath, $linkdir . "repo");
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

    while ($path ne "") {
	push @res, $path;
	$path = xdirname($path);
    }

    shift @res;
    return @res;
}

# like git diff, but between two repositories
sub git_inter_diff {
    my ($ra,$rb) = @_;

    return {} if (!defined($ra) && !defined($rb));

    die unless !defined($ra) or $ra->isa("Repository::Git::Head");
    die unless !defined($rb) or $rb->isa("Repository::Git::Head");

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

sub check_apply {
    my ($mdata, $apply, $apply_repo) = @_;

    die if $apply eq "";

    my $repo = $apply_repo;
    my $r = $mdata->{repos}{$repo};

    if (!$r) {
	retire "no repo for $repo, aborting";
    }

    if (!defined($r->revparse($apply))) {
	die "commit $apply isn't in $repo.";
    }

    if ($r->version eq "") {
	warn "no version for $repo";
	return;
    } elsif (grep { $_ eq $r->version } $r->git_parents($apply)) {
	warn "should be able to apply commit $apply to $apply_repo.";
	return;
    }

    if ($r->git_ancestor($apply, $r->version)) {
	retire "already applied $apply";
    }

    my $msg = "cannot apply commit $apply to $repo @" . $r->version . " != " . $r->revparse($apply . "^") . "\n";
    if ($r->git_ancestor($r->version, $apply)) {
	my $d = $r->git_find_missing_link($r->version, $apply);
	if ($d) {
	    $msg .= "missing link for $repo:\n";

	    $msg .= `cd $pwd/$repo; git log -1 $d`;
	} else {
	    $msg .= "cannot find missing link\n";

	}
    }
    if ($r->git_ancestor($apply, "HEAD") &&
	$r->git_ancestor($r->version, "HEAD")) {
	my $d = $r->git_find_descendant("HEAD", $apply, $r->version);
	$msg .= "but all will be good in the future.\n";
	$msg .= "merge commit:\n";

	$msg .= `cd $pwd/$repo; git log -1 $d`;

	retire $msg;
    }

    $msg .= " repo ancestors:\n";
    $msg .= "".$r->revparse($r->version."")."\n";
    $msg .= "".$r->revparse($r->version."~1")."\n";
    $msg .= "".$r->revparse($r->version."~2")."\n";
    $msg .= "".$r->revparse($r->version."~3")."\n";
    $msg .= "".$r->revparse($r->version."~4")."\n";
    $msg .= " commit ancestors:\n";
    $msg .= "".$r->revparse($apply."")."\n";
    $msg .= "".$r->revparse($apply."~1")."\n";
    $msg .= "".$r->revparse($apply."~2")."\n";
    $msg .= "".$r->revparse($apply."~3")."\n";
    $msg .= "".$r->revparse($apply."~4")."\n";

    $msg .= "\ngit log:\n";
    $msg .= `cd $pwd/$repo; git log -1`;
    $msg .= "\ncommit file:\n";
    $msg .= `head -8 $commit_message_file`;

    $msg .= "\n\n\n";

    die($msg);
}

sub update_manifest {
    my ($mdata, $dirstate) = @_;
    my $new_mdata;
    my $repo = $apply_repo;

    $do_rebuild_tree = 1;
    warn "rebuild tree! $apply_repo";
    my $date = `cd $pwd/$repo; git log -1 --pretty=tformat:\%ci $apply`;
    warn "date is $date";
    my $new_mdata = new ManifestData::Head::New($apply, $date);

    my %rset;
    for my $repo ($new_mdata->repos, $mdata->repos) {
	$rset{$repo} = 1;
    }

    for my $repo (sort keys %rset) {
	my $r0 = $mdata->repositories($repo);
	my $r1 = $new_mdata->repositories($repo);

	my $name0 = $r0 && $r0->name;
	my $name1 = $r1 && $r1->name;

	next if ($name0 eq $name1);

	warn "tree rb: $repo changed from " . $name0 . " to " . $name1;
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
	$mdata->repositories($repo)->find_changed($dirstate);
    }

    return $new_mdata;
}

-d "$outdir/head/.git" or die;

if ($do_new_versions) {
    nsystem("rm -rf $outdir/head/.pipcet-ro/versions/*");
}

if ($do_new_versions) {
    if (defined($apply_last_manifest) && !defined($date)) {
	my $mdate = `cd '$pwd/.repo/manifests'; git log -1 --pretty=tformat:\%ci $apply_last_manifest`;
	chomp($mdate);
	$date = $mdate;
    }
    if (!defined($apply_last_manifest)) {
	my $mm = `cd '$pwd/.repo/manifests'; git log -1 --first-parent --pretty=tformat:\%H --until='$date'`;
	chomp($mm);
	$apply_last_manifest = $mm;
    }
} else {
    my $v = ManifestData::read_version({}, ".repo/manifests/");

    $apply_last_manifest = $v;
}

my $mdata_head = new ManifestData::Head::New($apply_last_manifest, $date);
my $dirstate_head = new DirState($mdata_head);

my $mdata_head_old = new ManifestData::Head($apply_last_manifest, $date);
my $dirstate_head_old = new DirState($mdata_head_old);

my $mdata_head_new = new ManifestData::Head::New($apply_last_manifest, $date);
my $dirstate_head_new = new DirState($mdata_head_new);

if (defined($apply) and defined($apply_repo)) {
    check_apply($mdata_head, $apply, $apply_repo);
}

unless ($do_new_symlinks) {
    my @dirs = split(/\0/, `cd '$outdir/head'; find -name .git -prune -o -type d -print0`);

    for my $dir (@dirs) {
	$dir =~ s/^\.\///;
	$dir =~ s/\/*$//;
	$dirstate_head->store_item($dir, {changed=>1});
    }

    my @files = split(/\0/, `cd '$outdir/head'; find -name .git -prune -o -type f -print0`);

    for my $file (@files) {
	$file =~ s/^\.\///;
	$file =~ s/\/*$//;
	$dirstate_head->store_item($file, {changed=>1});
    }

    my @files = split(/\0/, `cd '$outdir/head'; find -name .git -prune -o -type l -print0`);

    for my $file (@files) {
	$file =~ s/^\.\///;
	$file =~ s/\/*$//;
	my $absdst = rel2abs(readlink("$outdir/head/$file"), xdirname("$outdir/head/$file"));
	unless (begins_with($absdst, "$outdir/repo-overlay") or
		begins_with($absdst, "$outdir/other-repositories")) {
	    $dirstate_head->store_item($file, {changed=>1});
	}
    }
}

if (defined($apply_repo_name) and !defined($apply_repo)) {
    for my $repo ($mdata_head->repos) {
	if ($mdata_head->{repos}{$repo}->name eq $apply_repo_name) {
	    $apply_repo = $repo;
	    warn "found repo to apply to: $apply_repo for $apply_repo_name";
	    last;
	}
    }

    retire "couldn't find repo $apply_repo_name, aborting" unless defined($apply_repo);

    check_apply($mdata_head, $apply, $apply_repo);
}

if ($do_new_symlinks) {
} elsif (defined($apply_repo)) {
    # rm -rf dangling-symlink/ doesn't delete anything. Learn
    # something new every day.
    die if $apply_repo =~ /^\/*$/;
    nsystem("rm -rf $outdir/head/" . ($apply_repo =~ s/\/$//r));
    nsystem("rm -rf $outdir/wd/" . ($apply_repo =~ s/\/$//r));
}

if (defined($apply) and defined($apply_repo) and
    !$do_new_symlinks and !$do_new_versions) {
    die if $mdata_head->{repos}{$apply_repo}->name eq "";
}

if ($do_new_symlinks) {
    setup_repo_links();
}

if (defined($apply) and defined($apply_repo) and !defined($apply_repo_name)) {
    my $manifest = $apply_last_manifest // "HEAD";
    my $mdata = new ManifestData::Head::New($manifest);
    my $name = $mdata->{repos}{$apply_repo}->name;

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

    $dirstate_head->snapshot("$outdir/head", $apply_repo);
} else {
    $dirstate_head->snapshot("$outdir/head");
}

#$dirstate_head_old->snapshot("$outdir/head-old") if $do_head_old;
#$dirstate_head_new->snapshot("$outdir/head-new") if $do_head_new;

$do_wd &&= !(defined($apply) and defined($apply_repo) and
	     !$do_new_symlinks and !$do_new_versions);

if ($do_wd) {
    my $mdata_wd = new ManifestData::WD();
    my $dirstate_wd = new DirState($mdata_wd);
    $dirstate_wd->snapshot("$outdir/wd");
}


nsystem("rm $outdir/repo-overlay 2>/dev/null"); #XXX lock
nsystem("ln -s $pwd $outdir/repo-overlay") or die;

if ($do_commit and defined($commit_message_file)) {
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
	my $name = $r->name;
	my $url = $r->url;
	my $head;

	$head = $r->head if $r->can("head");
	my $comment;
	$comment = $r->git(log => "-1", "$head") if $r->can("git");
	$comment =~ s/^/# /msg;

	mkdirp("$outdir/head/.pipcet-ro/versions/$repo");
	open $version_fh, ">$outdir/head/.pipcet-ro/versions/$repo"."version.txt";
	print $version_fh "$repo: $head $name $url\n$comment\n";
	close $version_fh;
    }

    if ($do_commit) {
	nsystem("cd $outdir/head; git add --all .; git commit -m 'versioning commit for $apply' " .
		(defined($commit_authordate) ? "--date '$commit_authordate' " : "") .
		(defined($commit_author) ? "--author '$commit_author' " : "")) or die;
    }
}

# useful commands:
# mkdir ~/tmp-repo-overlay/head
# git clone ~/jordan-android/ ~/tmp-repo-overlay/head/
# time perl ~/repo-tools/repo-overlay.pl --date=March.1 --new-symlinks --new-versions --out=/home/pip/tmp-repo-overlay
# perl ~/repo-tools/repo-log.pl --since=March.1 --additional-dir=/home/pip/tmp-repo-overlay/other-repositories --just-shas --commit-dir=/home/pip/tmp-repo-overlay/commits|tac|while read; do sh -c "perl ~/repo-tools/repo-overlay.pl --commit --emancipate $REPLY --out=/home/pip/tmp-repo-overlay" && sh -c "perl ~/repo-tools/repo-overlay.pl --commit $REPLY --out=/home/pip/tmp-repo-overlay" || break; done


#  repo-overlay.pl -- sync repository to wd/ head/
#  diff -ur repo-overlay/ wd/|(cd repo-overlay; patch -p1) -- sync wd/ to repository (doesn't handle new/deleted files)
#  diff -urNx .git -x .repo -x out -x out-old repo-overlay/ wd/|(cd repo-overlay; patch -p1)

# perl ~/repo-tools/repo-overlay.pl --new-symlinks --new-versions --out=/home/pip/tmp-repo-overlay
# perl ~/repo-tools/repo-log.pl --just-shas|tac|while read && echo $REPLY && sh -c "perl ~/repo-tools/repo-overlay.pl $REPLY --out=/home/pip/tmp-repo-overlay"; do true; done
# perl ~/repo-tools/repo-log.pl --just-shas|tac|while read; do echo $REPLY; sh -c "perl ~/repo-tools/repo-overlay.pl $REPLY --out=/home/pip/tmp-repo-overlay"; done

# perl ~/repo-tools/repo-log.pl --just-shas --commit-dir=/home/pip/tmp-repo-overlay/commits|tac|while read; do echo "$REPLY"; sh -c "perl ~/repo-tools/repo-overlay.pl --emancipate $REPLY --out=/home/pip/tmp-repo-overlay"; sh -c "perl ~/repo-tools/repo-overlay.pl $REPLY --out=/home/pip/tmp-repo-overlay"; done

# perl ~/repo-tools/repo-log.pl --just-shas --commit-dir=/home/pip/tmp-repo-overlay/commits|tac|while read; do echo "$REPLY"; sh -c "perl ~/repo-tools/repo-overlay.pl --commit --emancipate $REPLY --out=/home/pip/tmp-repo-overlay"; sh -c "perl ~/repo-tools/repo-overlay.pl --commit $REPLY --out=/home/pip/tmp-repo-overlay"; done

# perl ~/repo-tools/repo-log.pl --additional-dir=/home/pip/tmp-repo-overlay/other-repositories --just-shas --commit-dir=/home/pip/tmp-repo-overlay/commits|tac|while read; do sh -c "perl ~/repo-tools/repo-overlay.pl --commit --emancipate $REPLY --out=/home/pip/tmp-repo-overlay" && sh -c "perl ~/repo-tools/repo-overlay.pl --commit $REPLY --out=/home/pip/tmp-repo-overlay" || break; done

exit(0);

# Local Variables:
# eval: (add-hook 'before-save-hook (quote whitespace-cleanup))
# End:
