package App::Sets::Sort;

# ABSTRACT: sort handling

use strict;
use warnings;
use English qw( -no_match_vars );
use 5.010;
use App::Sets::Iterator;
use File::Temp qw< tempfile >;
use Fcntl qw< :seek >;
use Log::Log4perl::Tiny qw< :easy :dead_if_first >;
use base 'Exporter';

our @EXPORT_OK = qw< sort_filehandle internal_sort_filehandle >;
our @EXPORT = qw< sort_filehandle >;
our %EXPORT_TAGS = (
   default => [ @EXPORT ],
   all => [ @EXPORT_OK ],
);

sub sort_filehandle {
   my ($filename) = @_;
   state $has_sort = 1;

   if ($has_sort) {
      if (open my $fh, '-|', 'sort', '-u', $filename) {
         return $fh;
      }
      WARN "cannot use system sort, falling back to internal implementation";
      $has_sort = 0; # from now on, use internal sort
   }

   return internal_sort_filehandle($filename);
}

sub internal_sort_filehandle {
   my ($filename) = @_;

   # Open input stream
   open my $ifh, '<', $filename
      or LOGDIE "open('$filename'): $OS_ERROR";

   # Maximum values hints taken from Perl Power Tools' sort
   my $max_records = $ENV{SETS_MAX_RECORDS} || 200_000;
   my $max_files = $ENV{SETS_MAX_FILES} || 40;
   my (@records, @fhs);
   while (<$ifh>) {
      chomp;
      push @records, $_;
      if (@records >= $max_records) {
         push @fhs, _flush_to_temp(\@records);
         _compact(\@fhs) if @fhs >= $max_files - 1;
      }
   }

   push @fhs, _flush_to_temp(\@records) if @records;
   _compact(\@fhs);
   return $fhs[0] if @fhs;

   # seems like the file was empty... so it's sorted
   seek $ifh, 0, SEEK_SET;
   return $ifh;
}

sub _flush_to_temp {
   my ($records) = @_;
   my $tfh = tempfile(UNLINK => 1);
   my $previous;
   for my $item (sort @$records) {
      next if defined($previous) && $previous eq $item;
      print {$tfh} $item, $INPUT_RECORD_SEPARATOR;
   }
   @$records = ();
   seek $tfh, 0, SEEK_SET;
   return $tfh;
}

sub _compact {
   my ($fhs) = @_;
   return if @$fhs == 1;

   # where the output will end up
   my $ofh = tempfile(UNLINK => 1);

   # convenience hash for tracking all contributors
   my %its = map {
      my $fh = $fhs->[$_];
      $_ => App::Sets::Iterator->new(
         sub {
            my $retval = <$fh>;
            return unless defined $retval;
            chomp $retval;
            return $retval;
         }
       )
   } 0 .. $#$fhs;

   # iterate until all contributors are exhausted
   while (scalar keys %its) {

      # select the best (i.e. "lower"), cleanup on the way
      my $best;
      my @keys = keys %its;
      for my $key (@keys) {
         my $head = $its{$key}->head();
         if (! defined $head) {
            delete $its{$key};
            next;
         }
         elsif ((! defined $best) || ($best gt $head)) {
            $best = $head;
         }
      }
      last unless defined $best;
      print {$ofh} $best, $INPUT_RECORD_SEPARATOR;

      # get rid of the best in all iterators, cleanup on the way
      @keys = keys %its;
      KEY:
      for my $key (@keys) {
         my $head;
         while (defined($head = $its{$key}->head())) {
            next KEY if $head ne $best;
            $its{$key}->drop()
         }
         delete $its{$key};
      }
   }

   # rewind, finalize compacting, return
   seek $ofh, 0, SEEK_SET;
   @$fhs = ($ofh);
   return;
}

1;
__END__
