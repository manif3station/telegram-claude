#!/usr/bin/env perl
use strict;
use warnings;

use Test::More;

my @cli_files = qw(
  Makefile
  make.cmd
  cli/install
  cli/start
  cli/stop
  cli/e2e
  cli/check-message
  cli/get-me
  cli/updates
  cli/download
  cli/pair
  cli/reply
  cli/send-photo
  cli/send-audio
  cli/send-document
  cli/auto-reply-start
);

for my $path (@cli_files) {
    ok( -f $path, "$path exists" );
    if ( $path eq 'Makefile' || $path eq 'make.cmd' ) {
        pass("$path is present for skill-install auto-setup");
        next;
    }
    ok( -x $path, "$path is executable" );
    my $content = do {
        open my $fh, '<', $path or die $!;
        local $/;
        <$fh>;
    };
    like( $content, qr/^#!\/usr\/bin\/env perl/m, "$path uses perl shebang" );
}

done_testing;
