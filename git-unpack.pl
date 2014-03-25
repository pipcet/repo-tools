use strict;

use File::Basename qw(dirname);
use File::Path qw(make_path);
use Getopt::Long qw(GetOptions GetOptionsFromString :config auto_version auto_help);
use File::PathConvert qw(abs2rel rel2abs);
use File::Copy::Recursive qw(fcopy);
use File::Slurp qw(slurp read_dir);
use List::Util qw(min max);
use Git::Raw;
#use Carp::Always;

my $repository = Git::Raw::Repository->open(".");
my $head = $repository->head;
my $commit = $head->target;
my %knownids;

$knownids{$commit->id}++;

# all ancestor directories of a path
sub prefixes {
    my ($path) = @_;
    my @res;

    while ($path ne "" and $path ne "/") {
	push @res, $path;
	$path = xdirname($path);
    }

    shift @res;
    return @res;
}

sub mkdirp {
    my ($dir) = @_;

    for my $pref (prefixes($dir)) {
	die $pref if -l $pref;
    }

    make_path($dir);

    return 1;
}

sub xdirname {
    return dirname(@_) =~ s/^\.$//r;
}

sub symlink_relative {
    my ($src, $dst) = @_;
    my $relsrc = abs2rel($src, xdirname($dst));

    mkdirp(xdirname($dst)) or die "cannot make symlink $dst -> $relsrc";

    symlink($relsrc, $dst) or die "cannot make symlink $dst -> $relsrc";
}


sub write_file {
    my ($name, $value) = @_;
    my $fh;

    mkdirp(xdirname($name));

    open($fh, ">$name") or die;
    print $fh $value;
    close($fh);
}

package Packer;

use File::Basename qw(dirname basename);
use File::Path qw(make_path);
use Getopt::Long qw(GetOptions GetOptionsFromString :config auto_version auto_help);
use File::PathConvert qw(abs2rel rel2abs);
use File::Copy::Recursive qw(fcopy);

sub slurp {
    my ($file) = @_;

    return `cat $file`;
}

sub read_file {
    my ($name) = @_;

    return slurp($name);
}

sub pack_signature {
    my ($packer, $outdir) = @_;

    return Git::Raw::Signature->new(read_file("$outdir/name"),
				    read_file("$outdir/email"),
				    read_file("$outdir/time"),
				    read_file("$outdir/offset"));
}

sub pack_commit {
    my ($packer, $outdir) = @_;
    my $repo = $packer->{repo};
    my $id = basename($outdir);

    return $packer->{hash}{$id} if exists($packer->{hash}{$id});

    my $author = $packer->pack_signature("$outdir/author");
    my $committer = $packer->pack_signature("$outdir/committer");
    my $message = read_file("$outdir/message");
    my $tree = $packer->pack_tree_full("$outdir/tree-full");
    my @parents;

    for (my $i = 1; -l "$outdir/parents/$i"; $i++) {
	my $realpath = rel2abs(readlink("$outdir/parents/$i"), "$outdir/parents");
	push @parents, $packer->pack_commit($realpath, $repo);
    }


    warn($repo, $message, $author, $committer,
	 \@parents, $tree);
    $packer->{hash}{$id} =
	Git::Raw::Commit->create($repo, $message, $author, $committer,
				 \@parents, $tree);

    warn "id $id";

    return $packer->{hash}{$id};
}

sub pack_tree_full {
    my ($packer, $outdir) = @_;
    my $repo = $packer->{repo};
    my $id = basename(readlink($outdir));

    warn "id $id";

    # XXX. Need to understand the treebuilder object

    my $realpath = readlink($outdir);

    my $tree = Git::Raw::Tree::Builder->new($repo, $repo->lookup($id))->write;

    $id = $tree->id;
    warn "tree $tree $repo $id";

    $tree = $repo->lookup($id);
    warn "tree $tree $repo $id";

    return $tree;
}

sub new {
    my ($class, $repo) = @_;

    my $p = { repo => $repo, hash => {} };

    bless $p, $class;

    return $p;
}

package main;

sub unpack_signature {
    my ($o, $outdir) = @_;

    make_path($outdir);

    write_file("$outdir/name", $o->name);
    write_file("$outdir/email", $o->email);
    write_file("$outdir/time", $o->time);
    write_file("$outdir/offset", $o->offset);

    return $outdir;
}

sub unpack_commit {
    my ($o, $outdir) = @_;
    my $id = $o->id;

    make_path($outdir);

    write_file("$outdir/type", "commit");
    write_file("$outdir/message", $o->message);
    write_file("$outdir/raw_header", $o->raw_header);

    unpack_signature($o->author, "$outdir/author");
    unpack_signature($o->committer, "$outdir/committer");

    make_path($outdir."/parents");
    my @parents = @{$o->parents};
    my $i = 1;
    for my $parent (@parents) {
	my $id = $parent->id;
	$knownids{$id}++;
	symlink("../../../commit/$id", "$outdir/parents/$i");
	$i++;
    }
    my $id = $o->tree->id;
    $knownids{$id}++;
    symlink("../../tree-full/$id", "$outdir/tree-full");
    symlink("../../tree-minimal/$id", "$outdir/tree-minimal");

    return $outdir;
}

sub unpack_entry_minimal {
    my ($o, $outdir) = @_;

    make_path(xdirname($outdir));

    my $filemode = $o->filemode;
    write_file("$outdir/filemode", $filemode);

    my $id = $o->id;
    symlink_relative("../../../../../object/$id", "$outdir/object");

    return $outdir;
}

sub unpack_tree_minimal {
    my ($o, $outdir) = @_;
    my $id = $o->id;

    make_path($outdir);
    for my $entry (@{$o->entries}) {
	unpack_entry_minimal($entry, "$outdir/entries/" . $entry->name)
    }

    return $outdir;
}

sub unpack_entry_full {
    my ($o, $outdir) = @_;

    make_path(xdirname($outdir));

    my $filemode = $o->filemode;

    if ($filemode eq "100644") {
	write_file($outdir, $o->object->content);
    } elsif ($filemode eq "100755") {
	write_file($outdir, $o->object->content);
	chmod(0755, $outdir);
    } elsif ($filemode eq "040000") {
	unpack_tree_full($o->object, $outdir);
    } else {
	die "filemode $filemode";
    }

    return $outdir;
}

sub unpack_tree_full {
    my ($o, $outdir) = @_;
    my $id = $o->id;

    make_path($outdir);
    for my $entry (@{$o->entries}) {
	unpack_entry_full($entry, "$outdir/" . $entry->name)
    }

    return $outdir;
}

sub unpack_blob {
    my ($o, $outdir) = @_;
    my $id = $o->id;

    write_file($outdir, $o->content);

    return $outdir;
}

sub unpack_object {
    my ($o, $outdir) = @_;
    my $id = $o->id;
    my $path;

    if ($o->isa("Git::Raw::Commit")) {
	$path = unpack_commit($o, "$outdir/commit/$id");
    } elsif ($o->isa("Git::Raw::Tree")) {
	$path = unpack_tree_full($o, "$outdir/tree-full/$id");
	$path = unpack_tree_minimal($o, "$outdir/tree-minimal/$id");
    } elsif ($o->isa("Git::Raw::Blob")) {
	$path = unpack_blob($o, "$outdir/blob/$id");
    } else {
	die;
    }

    symlink_relative("../../$path", "$outdir/object/$id");

    return "$outdir/object/$id";
}

sub unpack_maybe {
    my ($repo, $id, $outdir) = @_;

    if (!-l "$outdir/object/$id" and !-e "$outdir/object/$id") {
	unpack_object($repo->lookup($id), $outdir);
	return 1;
    }

    return 0;
}

while(my $arg = shift(@ARGV)) {
    if ($arg eq "--help") {
	die "unhelpful";
    }
    if ($arg eq "--version") {
	die "no version";
    }
    if ($arg eq "meta-unpack") {
	my $didsomething;
	do {
	    $didsomething = 0;
	    for my $id (sort keys %knownids) {
		$didsomething += unpack_maybe($repository, $id, "metagit")
	    }
	} while($didsomething);

	for my $id (sort keys %knownids) {
	    if (-d "metagit/commit/$id") {
		for (my $pid = 1; -l "metagit/commit/$id/parents/$pid"; $pid++) {
		    system("cd metagit/commit/$id; mkdir -p diff; diff -urN parents/$pid/tree-full tree-full > diff/$pid");
		}
	    }
	}
	exit(0);
    }
    if ($arg eq "meta-pack") {
	system("mkdir metadotgit; cp -a .git metadotgit");
	my $repo = Git::Raw::Repository->open("metadotgit");

	my $packer = Packer->new($repo);

	for my $id (read_dir("metagit/commit")) {
	    if (-d "metagit/commit/$id") {
		$packer->pack_commit("metagit/commit/$id");
	    }
	}
	exit(0);
    }
    if ($arg eq "meta-addparent") {
	my ($child, $parent) = @ARGV;

	die unless -d "metagit/commit/$child" and -d "metagit/commit/$parent";

	my $i = max(read_dir("metagit/commit/$child/parents")) + 1;

	symlink("../../../commit/$parent", "metagit/commit/$child/parents/$i");

	exit(0);
    }

}
