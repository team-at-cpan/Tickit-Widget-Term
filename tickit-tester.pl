#!/usr/bin/env perl
use strict;
use warnings;
{
package Tickit::Widget::Term;
use parent qw(Tickit::Widget);

use Tickit::Style;
use constant WIDGET_PEN_FROM_STYLE => 1;

use POSIX;
use IO::Async::Stream;
use Variable::Disposition qw(retain_future);
use IO::Tty;
use IO::Pty;
use Log::Any qw($log);

sub new {
	my ($class, %args) = @_;
	my $self = $class->SUPER::new(%args);
	$self->{loop} = delete $args{loop};
	$self->init;
	$self
}

sub loop { shift->{loop} }

sub pty { shift->{pty} }

sub lines { 5 }

sub cols { 80 }

sub render_to_rb {
	my ($self, $rb, $rect) = @_;
	my $win = $self->window;

	my $line = 0;
	for my $item (@{$self->{writable}}) {
		my $txt = $item =~ s/[^[:print:]]+//gr;
		$rb->text_at($line++, 0, $txt, $self->get_style_pen);
	}
}

sub init {
	my ($self) = @_;
	my $loop = $self->loop;
	$loop->later(sub {
		$log->debug("Starting deferred PTY creation");
		$IO::Tty::DEBUG = 1;
		my $pty = IO::Pty->new;
		$self->{pty} = $pty;
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
								1 while $self->handle_terminal_output($buf);
#								print $$buf;
#								$$buf = '';
								0
							}
						);
#						$loop->add(
#							my $stdin = IO::Async::Stream->new_for_stdin(
#								on_read => sub {
#									my ($stream, $buf, $eof) = @_;
#									# print "stdin: " . $$buf . "\n";
#									$pty->write($$buf);
#									$$buf = '';
#									0
#								}
#							)
#						);
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

			# We'll arbitrarily pick a winsize here, and overwrite it when we obtain a window...
			# BUT! we might already have a window, so use that if available.
			if(my $win = $self->window) {
				$log->debugf("Applying PTY size from window: (%d,%d)", $win->lines, $win->cols);
				$slave->set_winsize($win->lines, $win->cols);
			} else {
				$log->debugf("Applying PTY size from defaults: (%d,%d)", $self->lines, $self->cols);
				$slave->set_winsize($self->lines, $self->cols);
			}
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
}

sub on_key {
	my ($self, $ev) = @_;
	$log->debugf("Had key event %s", $ev);
	if($ev->type eq 'key') {
		if($ev->str eq 'Enter') {
			$self->pty->write("\n");
		}
	} elsif($ev->type eq 'text') {
		$self->pty->write($ev->str);
	}
	$self->redraw;
}

sub handle_terminal_output {
	my ($self, $buf) = @_;
	$log->debugf("We have %d bytes of exciting new PTY data to examine", length $$buf);
	my $data = substr $$buf, 0, length($$buf), '';
	push @{$self->{writable}}, split /\n/, $data;
	length $$buf;
}

}

package main;
use Tickit::Async;
use IO::Async::Loop;
use Log::Any qw($log);
use Log::Any::Adapter qw(Stderr);

my $loop = IO::Async::Loop->new;
$loop->add(
	my $tickit = Tickit::Async->new
);
$tickit->set_root_widget(
	Tickit::Widget::Term->new(loop => $loop)
);
$tickit->run;

