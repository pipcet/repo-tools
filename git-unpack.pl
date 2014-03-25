use strict;

use File::Basename qw(dirname);
use File::Path qw(make_path);
use Getopt::Long qw(GetOptions GetOptionsFromString :config auto_version auto_help);
use File::PathConvert qw(abs2rel rel2abs);
use File::Copy::Recursive qw(fcopy);

use Git::Raw;
use Carp::Always;

my $repository = Git::Raw::Repository->open(".");
my $head = $repository->head;
my $commit = $head->target;

my %knownids;

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

sub unpack_signature {
    my ($o, $outdir) = @_;


    return $outdir;
}

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

$knownids{$commit->id}++;

my $didsomething;
do {
    $didsomething = 0;
    for my $id (sort keys %knownids) {
	$didsomething += unpack_maybe($repository, $id, "metagit")
    }
} while($didsomething);

for my $id (sort keys %knownids) {
    if (-d "metagit/commit/$id") {
	for (my $pid = 1; -e "metagit/commit/$id/parents/$pid"; $pid++) {
	    system("cd metagit/commit/$id; mkdir diff; diff -urN parents/$pid/tree-full tree-full > diff/$pid");
	}
    }
}
