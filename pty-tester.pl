use strict;
use warnings;

use Test::More;
use IO::Async::Loop;
use IO::Async::Stream;
use Variable::Disposition qw(retain_future);

my $loop = IO::Async::Loop->new;
use POSIX;

$loop->later(sub {
   require IO::Tty;
   require IO::Pty;
   $IO::Tty::DEBUG = 1;
   my $pty = IO::Pty->new;
   POSIX::setsid;
   pipe my $reader, my $writer or die "pipe - $!";
   $writer->autoflush(1);
   if(my $pid = fork // die "fork - $!") {
      $reader->close;
      $pty->make_slave_controlling_terminal if -T STDIN;
      my $slave = $pty->slave;
      $pty->close;
      $slave->clone_winsize_from(\*STDIN);
      $slave->set_raw;
      open STDIN, '<&' . $slave->fileno or die "STDIN - $!";
      open STDOUT, '>&' . $slave->fileno or die "STDOUT - $!";
      open STDERR, '>&' . $slave->fileno or die "STDERR - $!";
      $slave->close;
      exec { '/bin/bash' } '/bin/bash' or $writer->print($!+0);
      die "cannot exec - $!";
   }
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
});
$loop->run;

done_testing;


