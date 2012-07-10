#!/usr/bin/perl -w
#
use strict;
use Class::CSV;
use threads;
use threads::shared;
use Thread::Queue;
#use XML::Dumper;

my %fqdnarray;
open (FH, shift);
while (<FH>)
	{
	my @sharedarray :shared ;
	local $/="\n";
	chomp;
	local $/="\r";
	chomp;
	$fqdnarray{lc . '.eu.avonet.net'}  = \@sharedarray;
	}
close (FH);

# Setup CSV
my $fields =  ['fqdn', 'ip', 'reverse value', 'responds', 'NBName', 'is match?', 'Which Correct?'];
my $outputcsv = Class::CSV->new( fields=> $fields);
$outputcsv->add_line($fields);

# Setup Queues
my $forwardq= Thread::Queue->new(keys %fqdnarray);
$forwardq->enqueue(undef);
my $reverseq= Thread::Queue->new();
my $pingq= Thread::Queue->new();
my $nbq= Thread::Queue->new();

# Setup Threads
my @pingthreads = map{threads->create('pinger')} (0 .. 4);
my @nbthreads = map{threads->create('nblooker')} (0 .. 4);
my $reversethr = threads->create('reverselookup');
my $thr = threads->create('forwardlookup');
$thr->join;
$reversethr->join;
foreach (@pingthreads) {$_->join}
foreach (0 .. 4) {$nbq->enqueue(undef, undef)}
foreach (@nbthreads) {$_->join}

while ((my $fqdn, my $array) = each %fqdnarray)
	{
	my $ip = $$array[0];
	my $rname  =  $$array[1];
	my $responds = $$array[2];
	my $nbname = $$array[3];
	if ($ip =~ /N/) {$outputcsv->add_line([$fqdn, $ip, $rname, $nbname, $responds])}
	else
		{
		my $result = $rname eq $fqdn ? 'match' : 'no match';
		$outputcsv->add_line([$fqdn, $ip, $rname, $responds, $nbname, $result]);
		}
	}

foreach my $lineref (@{$outputcsv->lines()})
	{
	next unless ( ($lineref->get('responds') eq 'Yes') && ($lineref->get('is match?') eq 'no match') );
	my $nbname = $lineref->get('NBName');
	my $rname = $lineref->get('reverse value');
	my $fqdn = $lineref->get('fqdn');
	next if ($nbname eq 'No NB Answer');
	if ($rname =~ /$nbname/i) { $lineref->set('Which Correct?' => 'Reverse')}
	elsif ($fqdn =~ /$nbname/i) { $lineref->set('Which Correct?' => 'Forward')}
	else { $lineref->set('Which Correct?' => 'Neither')}
	}
$outputcsv->print;


sub forwardlookup
{
	require Net::DNS;
	my $res = Net::DNS::Resolver->new();
	while (my $fqdn = $forwardq->dequeue())
		{
		my $answerpacket = $res->query($fqdn, 'IN', 'A');
		if ($answerpacket)
			{
			my @ansarray = $answerpacket->answer;
			${$fqdnarray{$fqdn}}[0] = $ansarray[0]->address;
			$reverseq->enqueue( $fqdn, $ansarray[0]->address);
			$pingq->enqueue( $fqdn, $ansarray[0]->address);
			}
		else
			{
			${$fqdnarray{$fqdn}}[0] = 'Not Found';
			}
		}
	$reverseq->enqueue(undef, undef);
	foreach (0 .. 4) {$pingq->enqueue(undef, undef)}
}

sub reverselookup
{
	require Net::DNS;
	my $res = Net::DNS::Resolver->new();
	while ((my $fqdn, my $ip) = $reverseq->dequeue(2))
		{
		last unless $fqdn;
		my $answerpacket = $res->query($ip);
		if ($answerpacket)
			{
			my @ansarray = $answerpacket->answer;
			${$fqdnarray{$fqdn}}[1] = $ansarray[0]->ptrdname;
			}
		else
			{
			${$fqdnarray{$fqdn}}[1] = 'Not Found';
			}
		}
}

sub pinger
{
	require Net::Ping;
	my $pinger = Net::Ping->new('icmp');
	while ((my $fqdn, my $ip) = $pingq->dequeue(2))
		{
		last unless $fqdn;
		my $answer = $pinger->ping($ip, 1);
		${$fqdnarray{$fqdn}}[2] = $answer ? 'Yes' : 'No';
		if ($answer) {$nbq->enqueue( $fqdn, $ip)}
		}
}

sub nblooker
{
	require Net::NBName;
	my $nb = Net::NBName->new;
	while ((my $fqdn, my $ip) = $nbq->dequeue(2))
		{
		last unless $fqdn;
		my $answer = $nb->node_status($ip, 3);
		if ($answer)
			{
			foreach my $rr ($answer->names)
				{${$fqdnarray{$fqdn}}[3] = $rr->name if ($rr->suffix == 0 && $rr->G eq "UNIQUE")}
			}
		else {${$fqdnarray{$fqdn}}[3] = 'No NB Answer'}
		}
}
