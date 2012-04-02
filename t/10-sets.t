# vim: filetype=perl :
use strict;
use warnings;

#use Test::More tests => 1; # last test to print
use Test::More 'no_plan';  # substitute with previous line when done
use Data::Dumper;

use lib qw< t >;
use ASTest;

for my $test (test_specifications()) { # defined below
   my ($t1, $op, $t2, $result) = @{$test}{qw< t1 op t2 result >};
   $t1 = locate_file($t1);
   $t2 = locate_file($t2);
   {
      my $res = sets_run($t1, $op, $t2);
      is($res->{output}, $result, "$t1 $op $t2 - as separate items");
   }
   {
      my $res = sets_run("$t1 $op $t2");
      is($res->{output}, $result, "$t1 $op $t2 - as single string");
   }
}

sub test_specifications {
   return (
      {
         t1 => 'lista1',
         op => '-',
         t2 => 'lista2',
         result => 'nono
quarto
secondo
sesto
',
      },

   );
}
