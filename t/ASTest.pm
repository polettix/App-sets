package ASTest;

use strict;
use warnings;
use Carp;
use English qw< -no_match_vars >;

use Exporter qw< import >;
our @EXPORT_OK = qw<
   locate_file
   run
   sets_run
>;
our @EXPORT = @EXPORT_OK;

use File::Spec::Functions qw< catfile >;
use IPC::Open3 qw< open3 >;
use Symbol qw< gensym >;

sub locate_file {
   return catfile qw< t sample >, @_;
}

sub run {
   my ($e, $w, $r) = (gensym());
   my $pid = open3($w, $r, $e, @_);
   waitpid($pid, 0);
   croak "error invoking '@_', overall exit status $?"
      if $?;
   local $/;
   my $output = <$r>;
   my $error  = <$e>;
   return { output => $output, error => $error };
}

sub sets_run {
   return run qw< perl -I lib >, catfile(qw< bin sets >), @_;
}

1;
__END__

