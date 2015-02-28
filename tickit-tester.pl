#!/usr/bin/env perl
use strict;
use warnings;
{
package Tickit::Widget::Term;
use parent qw(Tickit::Widget);

use Tickit::Style;
use constant WIDGET_PEN_FROM_STYLE => 1;
use constant CAN_FOCUS => 1;

use POSIX;
use IO::Async::Stream;
use Variable::Disposition qw(retain_future);
use IO::Tty;
use IO::Pty;
use Log::Any qw($log);
use Tickit::Utils qw(textwidth);

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
	$rb->clip($rect);
	$rb->clear;

	for my $item (@{$self->{writable}}) {
		if(my $type = $item->{type}) {
			if($type eq 'erase') {
				$rb->eraserect($item->{rect}, $item->{pen});
			} elsif($type eq 'scroll') {
				$rb->eraserect($item->{rect}, $item->{pen});
			} else {
				$log->errorf("Unknown writequeue type %s", $type);
			}
		} else {
			$rb->text_at($item->{line}, $item->{col}, $item->{text}, $item->{pen});
		}
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
#			$self->push_text("\n");
		} elsif($ev->str eq 'Backspace') {
			$self->pty->write("\x08");
#			$self->push_text("\n");
		}
	} elsif($ev->type eq 'text') {
		$self->pty->write($ev->str);
#		$self->push_text($ev->str);
	}
	$self->redraw;
}

sub pen { $_[0]->{pen} //= $_[0]->get_style_pen->as_mutable }

my %csi_map = (
	m => sub {
		my ($self, @param) = @_;
		push @param, 0 unless @param;
		for(@param) {
			if($_ == 0) {
				$log->debug("SGR reset");
				delete $self->{pen};
			} elsif($_ == 1) {
				$log->debug("SGR bold");
				$self->pen->chattr(b => 1);
			} elsif($_ == 2) {
				$log->debug("SGR halfbright");
			} elsif($_ == 4) {
				$log->debug("SGR underscore");
				$self->pen->chattr(u => 1);
			} elsif($_ == 5) {
				$log->debug("SGR blink");
			} elsif($_ == 7) {
				$log->debug("SGR reverse");
				$self->pen->chattr(rv => 1);
			} elsif($_ == 10) {
				$log->debug("SGR primary font");
			} elsif($_ == 11) {
				$log->debug("SGR first alt");
			} elsif($_ == 12) {
				$log->debug("SGR second alt");
			} elsif($_ == 21) {
				$log->debug("SGR double-underline");
			} elsif($_ == 22) {
				$log->debug("SGR normal intensity");
				$self->pen->chattr(b => 0);
			} elsif($_ == 24) {
				$log->debug("SGR disable underline");
				$self->pen->chattr(u => 0);
			} elsif($_ == 25) {
				$log->debug("SGR disable blink");
			} elsif($_ == 27) {
				$log->debug("SGR disable RV");
				$self->pen->chattr(rv => 0);
			} elsif($_ >= 30 && $_ <= 37) {
				my $fg = $_ - 30;
				$log->debugf("SGR fg = %d", $fg);
				$self->pen->chattr(fg => $fg);
			} elsif($_ == 38) {
				$log->debug("SGR underscore on, default fg");
				$self->pen->chattr(fg => $self->get_style_pen->getattr('fg'));
				$self->pen->chattr(u => 1);
			} elsif($_ == 39) {
				$log->debug("SGR underscore off, default fg");
				$self->pen->chattr(fg => $self->get_style_pen->getattr('fg'));
				$self->pen->chattr(u => 0);
			} elsif($_ >= 40 && $_ <= 47) {
				my $bg = $_ - 30;
				$log->debugf("SGR bg = %d", $bg);
				$self->pen->chattr(bg => $bg);
			} elsif($_ == 49) {
				$log->debug("SGR bg = default");
				$self->pen->chattr(bg => $self->get_style_pen->getattr('bg'));
			} else {
				$log->warnf("SGR unknown parameter %s", $_);
			}
		}
	},
	H => sub {
		my ($self, $line, $col) = @_;
		$line //= 0;
		$col //= 0;
		$log->debugf("SGR CUP %d, %d", $line, $col);
		$self->{terminal_line} = $line - 1;
		$self->{terminal_col} = $col - 1;
		$self->update_cursor;
	},
	J => sub {
		my ($self, $type) = @_;
		$type //= 0;
		$log->debugf("SGR ED %d", $type);
		@{$self->{writable}} = ();
		$self->{terminal_line} = 0;
		$self->{terminal_col} = 0;
		$self->update_cursor;
		$self->redraw;
	},
	K => sub {
		my ($self, $type) = @_;
		$type //= 0;
		$log->debugf("SGR EL %d", $type);
		push @{$self->{writable}}, {
			type => 'erase',
			pen  => $self->pen->as_immutable,
			rect => Tickit::Rect->new(
				top  => $self->terminal_line,
				left => (
					$type == 0
					? $self->terminal_col
					: 0
				),
				cols => (
					$type == 1
					? $self->terminal_col
					: -1
				),
				lines => 1,
			)
		};
		$self->redraw;
	},
	d => sub {
		my ($self, $line) = @_;
		$line //= 0;
		$log->debugf("SGR VPA %d", $line);
		$self->{terminal_line} = $line - 1;
		$self->update_cursor;
	},
	g => sub {
		my ($self, $type) = @_;
		$log->debugf("CSI TBC %d", $type);
		if($type) {
			if($type == 3) {
				@{$self->{tab_stops}} = ();
			} else {
				$log->warnf("Tab clear requested with unknown parameter (expected 3) - %s", $type);
			}
		} else {
			extract_by { $_ == $self->terminal_col } @{$self->{tab_stops}}
		}
	}
);

sub csi_map {
	my ($self, $action) = @_;
	return undef unless exists $csi_map{$action};
	sub { $csi_map{$action}->($self, @_) }
}

use constant {
	NORMAL => 0,
	ESC => 1,
	CSI => 2,
};

sub handle_terminal_output {
	my ($self, $buf) = @_;
	$log->debugf("We have %d bytes of exciting new PTY data to examine", length $$buf);
	for($$buf) {
		my $mode = NORMAL;
		BREAKOUT:
		while(1) {
			# CAN/SUB abort escape sequence - i.e. switch to normal mode immediately
			if(/\G\x18/gc) {
				$log->debugf("CAN, bail out of escape mode (was %d)", $mode);
				$mode = NORMAL;
				redo BREAKOUT;
			} elsif(/\G\x1A/gc) {
				$log->debugf("SUB, bail out of escape mode (was %d)", $mode);
				$mode = NORMAL;
				redo BREAKOUT;
			} elsif(/\G\x07/gc) {
				$log->debug("BEEP");
				redo BREAKOUT;
			} elsif(/\G\x08/gc) {
				$log->debug("Backspace");
				redo BREAKOUT;
			} elsif(/\G([\x0A\x0B\x0C])/gc) {
				$log->debugf("Linefeed of some description (%s)", ord $1);
				$self->push_text("\n");
				redo BREAKOUT;
			} elsif(/\G\x0D/gc) {
				$log->debug("CR");
				redo BREAKOUT;
			} elsif(/\G\x0E/gc) {
				$log->debug("Activate G1 character set");
				redo BREAKOUT;
			} elsif(/\G\x0F/gc) {
				$log->debug("Activate G0 character set");
				redo BREAKOUT;
			} elsif(/\G\x7F/gc) {
				$log->debug("DEL (ignored)");
				redo BREAKOUT;
			} elsif(/\G\x9B/gc) {
				$log->debug("CSI");
				$mode = CSI;
				redo BREAKOUT;
			}

			if($mode == NORMAL) {
				if(/\G([^\x00-\x1F]+)/gc) {
					$log->debugf("Text sequence: %s", $1);
					$self->push_text($1);
				} elsif(/\G\x1B/gc) {
					$log->debugf("Escape sequence: %s", sprintf '%v02x', substr $_, pos, 8);
					$mode = ESC;
				} elsif(/\G\x09/gc) {
					my $col = $self->find_next_tab;
					$log->debugf("Tab - will move to %d", $col);
					$self->{terminal_col} = $col;
					$self->update_cursor;
					$mode = ESC;
				} else {
					$log->debugf("No characters of interest found, must be text: %s", substr $_, pos() // 0, -1);
					last BREAKOUT
				}
			} elsif($mode == ESC) {
				if(/\Gc/gc) {
					$log->debug("ESC: Reset");
					$mode = NORMAL;
				} elsif(/\GD/gc) {
					$log->debug("ESC: Linefeed");
					$mode = NORMAL;
				} elsif(/\GE/gc) {
					$log->debug("ESC: Newline");
					$mode = NORMAL;
				} elsif(/\GH/gc) {
					$log->debug("ESC: Set tab stop");
					$mode = NORMAL;
				} elsif(/\GM/gc) {
					$log->debug("ESC: Reverse line feed");
					$mode = NORMAL;
				} elsif(/\GZ/gc) {
					$log->debug("ESC: DEC ident");
					$mode = NORMAL;
				} elsif(/\G\[/gc) {
					$log->debug("ESC: CSI");
					$mode = CSI;
				} elsif(/\G7/gc) {
					$log->debug("ESC: DECSC");
					$self->push_state;
					$mode = NORMAL;
				} elsif(/\G8/gc) {
					$log->debug("ESC: DECSC");
					$self->pop_state;
					$mode = NORMAL;
				} elsif(/\G\(([B0UK])/gc) {
					$log->debugf("ESC: G0 charset %s", $1);
					$mode = NORMAL;
				} else {
					$log->debugf("Some other ESC thing: %s", substr $_, pos() // 0, 1);
					$mode = NORMAL;
				}
			} elsif($mode == CSI) {
				if(/\G\??([\d;]*)(.)/gc) {
					my ($action) = $2;
					my @param = split /;/, $1;
					$log->debugf("CSI: %s with %d parameters: %s", $action, 0 + @param, join ',', @param);
					if(my $code = $self->csi_map($action)) {
						$code->(@param);
					} else {
						$log->debugf("Unknown CSI action %s, had parameters: %s", $action, join ',', @param);
					}
					$mode = NORMAL;
				} else {
					$log->debugf("We are unknown CSI! %s (%s)", substr($_, pos()//0, 8), sprintf '%v02x', substr($_, pos()//0, 8));
					$mode = NORMAL;
				}
			}
		}
	}
	my $data = substr $$buf, 0, length($$buf), '';
#	push @{$self->{writable}}, split /\n/, $data;
	$self->redraw;
	length $$buf;
}

sub push_state {
	my ($self) = @_;
	push @{$self->{dec_state}}, {
		pen => $self->pen->as_mutable,
		line => $self->terminal_line,
		col => $self->terminal_col
	};
	$self
}

sub pop_state {
	my ($self) = @_;
	return $self unless my $state = pop @{$self->{dec_state}};
	$self->{pen} = $state->{pen};
	$self->{terminal_line} = $state->{line};
	$self->{terminal_col} = $state->{col};
	$self->update_cursor;
	$self
}

sub terminal_line { $_[0]->{terminal_line} //= 0 }
sub terminal_col { $_[0]->{terminal_col} //= 0 }

sub push_text {
	my ($self, $txt) = @_;
	for($txt) {
		if(/\G\n/gc) {
			$self->terminal_next_line
		} elsif(/\G([[:print:]]+)/gc) {
			my $chunk = $1;
			push @{$self->{writable}}, {
				text => $chunk,
				line => $self->terminal_line,
				col  => $self->terminal_col,
				pen  => $self->pen->as_immutable,
			};
			$self->{terminal_col} += textwidth $chunk;
		} else {
			$log->warnf("Unknown thing in text: %s", substr $_, pos()//0);
		}
	}
	$self->update_cursor;
}

sub available_lines {
	my ($self) = @_;
	return $self->lines unless my $win = $self->window;
	$win->lines
}
sub available_cols {
	my ($self) = @_;
	return $self->cols unless my $win = $self->window;
	$win->cols
}

sub terminal_next_line {
	my ($self) = @_;
	$self->{terminal_col} = 0;
	if(++$self->{terminal_line} >= $self->available_lines) {
		$log->infof("Scrolling required, line = %d", $self->terminal_line);
		$self->scroll(-1, 0);
	}
	$self->update_cursor
}

sub scroll {
	my ($self, $down, $right) = @_;
	$self->window->scroll($down, $right);
	for my $item (@{$self->{writable}}) {
		$item->{rect}->translate($down, $right) if $item->{rect};
		$item->{line} += $down if exists $item->{line};
		$item->{col} += $right if exists $item->{col};
	}
	$self->{terminal_line} += $down;
	$self->{terminal_col} += $right;
	$self->redraw;
}

sub update_cursor {
	my ($self) = @_;
	return unless my $win = $self->window;
	$win->cursor_at($self->terminal_line, $self->terminal_col);
}

}

package main;
use Tickit::Async;
use IO::Async::Loop;
use Log::Any qw($log);
use Log::Any::Adapter qw(Stderr);
use Tickit::Widget::Frame;

my $loop = IO::Async::Loop->new;
$loop->add(
	my $tickit = Tickit::Async->new
);
my $frame = Tickit::Widget::Frame->new(
	child => my $term = Tickit::Widget::Term->new(loop => $loop),
	title => 'shell',
	style => {
		linetype => 'single'
	},
);
$tickit->set_root_widget(
	$frame
);
$term->take_focus;
$tickit->run;

