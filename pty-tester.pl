use strict;
use warnings;

use Test::More;
use IO::Async::Loop;
use IO::Async::Stream;
use Variable::Disposition qw(retain_future);
use Log::Any qw($log);
use Log::Any::Adapter qw(Stdout);

my $loop = IO::Async::Loop->new;
use POSIX;

$loop->later(sub {
	$log->debug("Starting deferred PTY creation");
	require IO::Tty;
	require IO::Pty;
	$IO::Tty::DEBUG = 1;
	my $pty = IO::Pty->new;
	$log->debugf("New PTY at %s", $pty->ttyname);
	pipe my $reader, my $writer or die "pipe - $!";
	$log->debugf("Controlling pipe at FDs %d and %d", map $_->fileno, $reader, $writer);
	$writer->autoflush(1);
	if(my $pid = fork // die "fork - $!") {
		$log->debugf("Parent process had child pid %d", $pid);
		$writer->close;
		$pty->close_slave;
		$pty->set_raw;

		{
			$loop->add(
				my $rs = IO::Async::Stream->new(
					handle => $reader,
					on_read => sub { 0 }
				)
			);
			retain_future(
				$rs->read_until_eof->then(sub {
					my ($errno) = @_;
					warn "eof\n";
					$rs->close;
					if($errno) {
						$! = 0 + $errno;
						die "exec failed - $! ($errno)";
					}
					$pty->autoflush(1);
					STDOUT->autoflush(1);
					my $stream = IO::Async::Stream->new(
						handle => $pty,
						on_read => sub {
							my ($stream, $buf, $eof) = @_;
							print $$buf;
							$$buf = '';
							0
						}
					);
					$loop->add(
						my $stdin = IO::Async::Stream->new_for_stdin(
							on_read => sub {
								my ($stream, $buf, $eof) = @_;
								# print "stdin: " . $$buf . "\n";
								$pty->write($$buf);
								$$buf = '';
								0
							}
						)
					);
					$loop->add($stream);
				})
			);
		}
	} else {
		$log->debugf("Child process active on %d", $$);
		$reader->close;

		$pty->make_slave_controlling_terminal if -T STDIN;
		# somewhere around here I was expecting to need POSIX::setsid, but strace shows
		# that ->make_slave_controlling_terminal does this for us. which is nice.

		my $slave = $pty->slave;
		$pty->close;
		$slave->clone_winsize_from(\*STDIN);
		$slave->set_raw;

		# Redirect our STDIO/ERR towards the PTY
		open STDIN, '<&' . $slave->fileno or die "STDIN - $!";
		open STDOUT, '>&' . $slave->fileno or die "STDOUT - $!";
		open STDERR, '>&' . $slave->fileno or die "STDERR - $!";
		# ... and drop the original handle - in an exec scenario, F_CLOEXEC is probably going
		# to take care of this for us. On the other hand, if we're about to wade into a code block
		# instead, we don't really need a stray handle lying around for things to stumble over.
		$slave->close or die "cannot close original PTY? $!";

		# exec { '/bin/ls' } '/bin/ls' or $writer->print($! + 0);
		exec { '/bin/bash' } '/bin/bash' or $writer->print($! + 0);
		die "cannot exec - $!";
	}
});
$loop->run;

done_testing;


