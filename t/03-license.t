#!/usr/bin/env perl
use strict;
use warnings;

use Test::More;

ok( -f 'LICENSE', 'LICENSE file exists' );
my $license = do {
    open my $fh, '<', 'LICENSE' or die $!;
    local $/;
    <$fh>;
};
like( $license, qr/MIT License/, 'LICENSE contains MIT text' );

done_testing;
