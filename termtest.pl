#!/usr/bin/env perl
use strict;
use warnings;

use IO::Pty;
use IO::Tty;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Log::Any qw($log);
use Log::Any::Adapter qw(Stderr);

sub unblock($) {
	my ($fh) = @_;
	return $fh;
	my $flags = fcntl($fh, F_GETFL, 0)
		or die "Can't get flags for the socket: $!\n";

	$flags = fcntl($fh, F_SETFL, $flags | O_NONBLOCK)
		or die "Can't set flags for the socket: $!\n";
	$fh
}

$IO::Tty::DEBUG = 1;

my $pty = unblock(IO::Pty->new);
$log->debugf("TTY is %s", $pty->ttyname);
my $slave = unblock($pty->slave);
$pty->print("ls\n");
print while $_ = <$slave>;

