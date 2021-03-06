#!/usr/bin/perl
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
	#$fqdnarray{lc . '.eu.avonet.net'}  = \@sharedarray;
	$fqdnarray{lc()}  = \@sharedarray;
	}
close (FH);

my $ns = [qw/134.65.213.75/];
# Setup CSV
my $fields =  ['fqdn', 'ip', 'reverse value', 'responds', 'NBName', 'is match?', 'Which Correct?'];
my $outputcsv = Class::CSV->new( fields=> $fields);
$outputcsv->add_line($fields);

# Setup Queues
my $forwardq= Thread::Queue->new(keys %fqdnarray);
my $reverseq= Thread::Queue->new();
my $pingq= Thread::Queue->new();
my $nbq= Thread::Queue->new();

# Setup Threads
my @pingthreads = map{threads->create('pinger')} (0 .. 1);
my @nbthreads = map{threads->create('nblooker')} (0 .. 1);
my @reversethreads = map{threads->create('reverselookup')} (0 .. 1);
my @forthr = map{threads->create('forwardlookup')} (0 .. 1);
foreach (@forthr) { $forwardq->enqueue(undef) }
$|++;
do
	{
	printf "Forward-Q %u, Reverse-Q %u, Ping-Q %u, NB-Q %u     \r", $forwardq->pending(), $reverseq->pending(), $pingq->pending(), $nbq->pending();
	sleep 1;
	}
	while (($forwardq->pending() gt 0) or ($reverseq->pending() gt 0) or ($pingq->pending() gt 0) or ($nbq->pending() gt 0));

# Finalize Queues and Join threads
foreach (@forthr) { $_->join }
foreach (@reversethreads) { $reverseq->enqueue(undef, undef) }
foreach (@reversethreads) { $_->join }
foreach (@pingthreads) {$pingq->enqueue(undef, undef)}
foreach (@pingthreads) {$_->join}
foreach (@nbthreads) {$nbq->enqueue(undef, undef)}
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
open (FF, ">output.csv");
print FF $outputcsv->string;
close (FF);


sub forwardlookup
{
	require Net::DNS;
	my $res = Net::DNS::Resolver->new(nameservers=>$ns);
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
}

sub reverselookup
{
	require Net::DNS;
	my $res = Net::DNS::Resolver->new(nameservers=>$ns);
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
