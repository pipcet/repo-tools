#!/usr/bin/perl

use Getopt::Long qw(:config auto_version auto_help);

my $do_just_shas;

GetOptions(
    "just-shas!"=>\$do_just_shas,
    );

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
	    $h->{commit}->{rawdate} = `date -d '$1' +'%s'`;
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
    my ($class, $repo) = @_;
    my $h = { };

    #if (system("(cd '$repo'; grep -q Quarx2k .git/config)")) {
    #    return undef;
    #}
    
    $h->{commits} = [];
    $h->{n} = 0;
    $h->{repo} = $repo;
    my $tformat;
    $tformat = "* $repo %h by %an at %ci%n..CommitDate:%ci%n..%N%n..%s%b%n..SHA:%h";
    open($h->{fh}, "(cd '$repo'; git log -p -m --first-parent --pretty=tformat:'$tformat' --since='1 week ago' --date=iso)|") or die;

    return bless($h, $class);
}

package main;

my @repos = split(/\0/, `find  -name '.git' -print0 -o -name '.repo' -prune -o -path './out' -prune`);
#pop(@repos);
map { chomp; s/\.git$// } @repos;

my %r;
warn scalar(@repos) . " repos\n";
for my $repo (@repos) {
    my $r =  RepoStream->new($repo);
    if ($r) {
	$r{$repo} = $r;
    }
}

print " -*- mode: Diff; eval: (orgstruct++-mode 1); -*-\n";

while(1) {
    my @dates = sort { $b->[0] <=> $a->[0] } map { [$_->[0]{rawdate}, $_->[0], $_->[1]] } grep { defined($_->[0]) } map { [$_->peek, $_] } values(%r);

    if (scalar(@dates)) {
	if ($do_just_shas) {
	    print $dates[0][2]->get->{sha} . "\n";
	} else {
	    my $repo = $dates[0][2]->{repo};
	    my $raw = $dates[0][2]->get->{content};
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
