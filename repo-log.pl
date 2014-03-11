#!/usr/bin/perl

use Getopt::Long qw(:config auto_version auto_help);

use strict;

my $do_just_shas;
my $commit_dir;
my $since_date = "January.20";
my @repos;
my @additional_repos;
my @additional_dirs;
my $range;
my $sha2log;
GetOptions(
    "just-shas!" => \$do_just_shas,
    "commit-dir=s" => \$commit_dir,
    "since=s" => \$since_date,
    "repo=s" => \@repos,
    "additional-repo=s" => \@additional_repos,
    "additional-dir=s" => \@additional_dirs,
    "range=s" => \$range,
    "sha2log=s" => \$sha2log,
    );

@repos = split(/,/, join(",", @repos));
map { chomp; s/\/*$/\//; s/^\.\///; } @repos;

package RepoStream;

sub peek1 {
    my ($h) = @_;

    return undef if $h->{eof};

    my $line;
    if (defined($line = readline($h->{fh}))) {
	if ($line =~ /^\* /) {
	    if ($h->{commit}->{content} ne "") {
		push $h->{commits}, $h->{commit};
		$h->{commit} = { };
	    }
	    $h->{commit}->{content} = $line;
	} else {
	    $h->{commit}->{content} .= $line;
	}

	if ($line =~ /^\.\.CommitDate:[ \t]*(.*)$/) {
	    $h->{commit}->{date} = $1;
	    $h->{commit}->{commitdate} = $1;
	    $h->{commit}->{rawdate} = `date -d '$1' +'%s'`;
	}
	if ($line =~ /^\.\.Committer:[ \t]*(.*)$/) {
	    $h->{commit}->{committer} = $1;
	}
	if ($line =~ /^\.\.AuthorDate:[ \t]*(.*)$/) {
	    $h->{commit}->{authordate} = $1;
	}
	if ($line =~ /^\.\.Author:[ \t]*(.*)$/) {
	    $h->{commit}->{author} = $1;
	}
	if ($line =~ /^\.\.SHA:[ \t]*(.*)$/) {
	    $h->{commit}->{sha} = $1;
	}
    } else {
	$h->{eof} = 1;
	close($h->{fh});
	if ($h->{commit}->{content} ne "") {
	    push $h->{commits}, $h->{commit};
	    $h->{commit} = { };
	}
    }
}

sub peek {
    my ($h) = @_;
    my $n = $h->{n};
    while ((scalar(@{$h->{commits}}) <= $n)  and
	   !$h->{eof}) {
	$h->peek1();
    }

    if ($h->{eof}) {
	return undef;
    }

    return $h->{commits}->[$n];
}

sub get {
    my ($h) = @_;
    my $ret = $h->peek();
    if (defined($ret)) {
	$h->{n}++;
    }

    return $ret;
}

sub new {
    my ($class, $repo, $id, $name) = @_;
    my $h = { };

    #if (system("(cd '$repo'; grep -q Quarx2k .git/config)")) {
    #    return undef;
    #}

    $h->{commits} = [];
    $h->{n} = 0;
    $h->{repo} = $repo;
    $h->{id} = $id;
    $h->{name} = $name;
    my $tformat;
    if ($do_just_shas) {
	$tformat = "* $repo: %s %h by %an at %ci%n..Committer:%cn <%ce>%n..CommitDate:%ci%n..Author:%an <%ae>%n..AuthorDate:%ai%n..SHA:%H%n..%N%n..%s%n%w(0,1,1)%b%n%w(0,0,0)";
    } else {
	$tformat = "* $repo %h by %an at %ci%n..CommitDate:%ci%n..SHA:%H%n..%N%n..%s%n%w(0,6,9)%b%n%w(0,0,0)";
    }
    my $cmd = "git log -p --sparse --full-history --pretty=tformat:'$tformat' --date=iso $range";

    if (defined($sha2log)) {
	$cmd .= " '$sha2log'";
    }
    if (defined($since_date)) {
	$cmd .= " --since='$since_date'";
    }

    open($h->{fh}, "(cd '$repo'; $cmd)|") or die;

    return bless($h, $class);
}

package main;

sub begins_with {
    my ($a,$b,$noprefix) = @_;

    my $ret = substr($a, 0, length($b)) eq $b;

    if ($ret and $noprefix) {
	$$noprefix = substr($a, length($b));
    }

    return $ret;
}

if (!@repos) {
    for my $dir (".", @additional_dirs) {
	my @prepos = split(/\0/, `find $dir -name '.git' -print0 -o -name '.repo' -prune -o -path './out' -prune`);
	for my $prepo (@prepos) {
	    $prepo =~ s/\.git$//;
	    my $repo;
	    if (begins_with($prepo, "$dir/", \$repo)) {
		push @repos, [$prepo, $repo =~ s/\/$//r, $dir eq "." ? undef : $repo =~ s/\/$//r];
	    } else {
		die "mismatch: $prepo $dir"
	    }
	}
    }
}

unshift @repos, (
    [".repo/repo/", ".repo/repo", undef],
    [".repo/manifests/", ".repo/manifests", undef]);
push @repos, split(/,/, join(",", @additional_repos)) if (@additional_repos); #  XXX broken

my %r;
warn scalar(@repos) . " repos\n";
for my $repo (@repos) {
    my ($repodir, $repoid, $reponame) = @$repo;
    my $r =  RepoStream->new($repodir, $repoid, $reponame);
    if ($r) {
	$r{$repodir} = $r;
    }
}

print " -*- mode: Diff; eval: (orgstruct++-mode 1); -*-\n" unless $do_just_shas;

my $last_manifest;

while(1) {
    my @dates = sort { $b->[0] <=> $a->[0] } map { [$_->[0]{rawdate}, $_->[0], $_->[1]] } grep { defined($_->[0]) } map { [$_->peek, $_] } values(%r);

    if (scalar(@dates)) {
	my $commit_msg = undef;

	if (defined($commit_dir)) {
	    system("mkdir -p '$commit_dir'");

	    my $repo = $dates[0][2]->{repo};
	    my $entry = $dates[0][2]->peek;
	    $commit_msg = "$commit_dir/" . $entry->{sha};
	    my $raw = $entry->{content};
	    my $cooked = $raw;
	    $cooked =~ s/^\* *//msg;
	    $cooked =~ s/^(diff --git a\/([^ \t]*))/\*\* $repo$2\n$1/msg;
	    $cooked =~ s/\n+\*\*/\n\*\*/msg;
	    $cooked =~ s/^\.\.\n//msg;
	    $cooked =~ s/^\.\.//msg;
	    my $l;
	    if (($l = length($cooked)) > 10000) {
		$cooked = substr($cooked, 0, 10000) . "\n" . ($l-10000) . " bytes skipped\n"
	    }
	    my $fh;
	    open $fh, ">$commit_msg";
	    print $fh $cooked;
	    close $fh;
	}

	if ($do_just_shas) {
	    my $repo = $dates[0][2]->{repo};
	    my $repoid = $r{$repo}->{id};
	    my $entry = $dates[0][2]->get;

	    my @msg;
	    push @msg, "--commit-commitdate='" . $entry->{commitdate} . "'";
	    push @msg, "--apply=" . $entry->{sha};
	    push @msg, "--apply-repo=" . $repoid;
	    push @msg, "--commit-message-file=$commit_msg" if defined($commit_msg);
	    push @msg, "--commit-authordate='".$entry->{authordate}."'";
	    push @msg, "--commit-committer='".$entry->{committer}."'";
	    push @msg, "--commit-author='" . $entry->{author} . "'";
	    push @msg, "--apply-use-manifest=" . $last_manifest if defined($last_manifest);

	    print join(" ", @msg) . "\n";

	    if ($repo eq ".repo/manifests/") {
		$last_manifest = $entry->{sha};
		warn "manifest updated to $last_manifest";
	    }
	} else {
	    my $repo = $dates[0][2]->{repo};
	    my $entry = $dates[0][2]->get;
	    my $raw = $entry->{content};
	    my $cooked = $raw;
	    $cooked =~ s/^(diff --git a\/([^ \t]*))/\*\* $repo$2\n$1/msg;
	    $cooked =~ s/\n+\*\*/\n\*\*/msg;
	    $cooked =~ s/^\.\.\n//msg;
	    my $l;
	    if (($l = length($cooked)) > 1000000) {
		$cooked = substr($cooked, 0, 1000) . "\n" . ($l-1000) . " bytes skipped\n"
	    }
	    print $cooked;
	}
    } else {
	last;
    }
}
