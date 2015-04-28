package App::Sets;

# ABSTRACT: set operations in Perl

use strict;
use warnings;
use English qw( -no_match_vars );
use 5.010;
use Getopt::Long
  qw< GetOptionsFromArray :config pass_through no_ignore_case bundling >;
use Pod::Usage qw< pod2usage >;
use Log::Log4perl::Tiny qw< :easy :dead_if_first LOGLEVEL >;
use App::Sets::Parser;
use App::Sets::Iterator;

my %config = (
   loglevel => 'INFO',
   parsedebug => 0,
);

sub populate_config {
   my (@args) = @_;

   $config{sorted} = 1                if $ENV{SETS_SORTED};
   $config{trim}   = 1                if $ENV{SETS_TRIM};
   $config{cache}  = $ENV{SETS_CACHE} if exists $ENV{SETS_CACHE};
   $config{loglevel}  = $ENV{SETS_LOGLEVEL}
      if exists $ENV{SETS_LOGLEVEL};
   $config{parsedebug}  = $ENV{SETS_PARSEDEBUG}
      if exists $ENV{SETS_PARSEDEBUG};
   GetOptionsFromArray(
      \@args, \%config, qw< man help usage version
        trim|t! sorted|s! cache|cache-sorted|S=s
        loglevel|l=s
        >
     )
     or pod2usage(
      -verbose  => 99,
      -sections => 'USAGE',
     );
   our $VERSION; ${VERSION} //= '0.972' unless defined $VERSION;
   pod2usage(message => "$0 $VERSION", -verbose => 99, -sections => ' ')
     if $config{version};
   pod2usage(
      -verbose  => 99,
      -sections => 'USAGE'
   ) if $config{usage};
   pod2usage(
      -verbose  => 99,
      -sections => 'USAGE|EXAMPLES|OPTIONS'
   ) if $config{help};
   pod2usage(-verbose => 2) if $config{man};

   LOGLEVEL $config{loglevel};

   $config{cache} = '.sorted'
     if exists $config{cache}
        && !(defined($config{cache}) && length($config{cache}));
   $config{sorted} = 1 if exists $config{cache};

   if (exists $config{cache}) {
      INFO "using sort cache or generating it when not available";
   }
   elsif ($config{sorted}) {
      INFO "assuming input files are sorted";
   }
   INFO "trimming away leading/trailing whitespaces"
     if $config{trim};

   pod2usage(
      -verbose  => 99,
      -sections => 'USAGE',
   ) unless @args;

   return @args;
} ## end sub populate_config

sub run {
   my $package = shift;
   my @args    = populate_config(@_);

   my $input;
   if (@args > 1) {
      shift @args if $args[0] eq '--';
      LOGDIE "only file op file [op file...] "
        . "with multiple parameters (@args)...\n"
        unless @args % 2;
      my @chunks;
      while (@args) {
         push @chunks, escape(shift @args);
         push @chunks, shift @args if @args;
      }
      $input = join ' ', @chunks;
   } ## end if (@args > 1)
   else {
      $input = shift @args;
   }

   LOGLEVEL('DEBUG') if $config{parsedebug};
   DEBUG "parsing >$input<";
   my $expression = App::Sets::Parser::parse($input, 0);
   LOGLEVEL($config{loglevel});

   my $it = expression($expression);
   while (defined(my $item = $it->drop())) {
      print $item;
      print "\n" if $config{trim};
   }
   return;
} ## end sub run

sub escape {
   my ($text) = @_;
   $text =~ s{(\W)}{\\$1}gmxs;
   return $text;
}

sub expression {
   my ($expression) = @_;
   if (ref $expression) {    # operation
      my ($op, $l, $r) = @$expression;
      return __PACKAGE__->can($op)->(expression($l), expression($r));
   }
   else {                    # plain file
      return file($expression);
   }
} ## end sub expression

sub _sort_filehandle {
   my ($filename) = @_;
   open my $fh, '-|', 'sort', '-u', $filename
     or LOGDIE "open() sort -u '$filename': $OS_ERROR";
   return $fh;
} ## end sub _sort_filehandle

sub file {
   my ($filename) = @_;
   LOGDIE "invalid file '$filename'\n"
     unless -r $filename && !-d $filename;

   if ($config{cache}) {
      my $cache_filename = $filename . $config{cache};
      if (!-e $cache_filename) {    # generate cache file
         WARN "generating cached sorted file "
           . "'$cache_filename', might wait a bit...";
         my $ifh = _sort_filehandle($filename);
         open my $ofh, '>', $cache_filename
           or LOGDIE "open('$cache_filename') for output: $OS_ERROR";
         while (<$ifh>) {
            print {$ofh} $_;
         }
         close $ofh or LOGDIE "close('$cache_filename'): $OS_ERROR";
      } ## end if (!-e $cache_filename)
      INFO "using '$cache_filename' (assumed to be sorted) "
        . "instead of '$filename'";
      $filename = $cache_filename;
   } ## end if ($config{cache})

   my $fh;
   if ($config{sorted}) {
      INFO "opening '$filename', assuming it is already sorted"
        unless $config{cache};
      open $fh, '<', $filename
        or LOGDIE "open('$filename'): $OS_ERROR";
   } ## end if ($config{sorted})
   else {
      INFO "opening '$filename' and sorting on the fly";
      $fh = _sort_filehandle($filename);
   }
   return App::Sets::Iterator->new(
      sub {
         my $retval = <$fh>;
         return unless defined $retval;
         $retval =~ s{\A\s+|\s+\z}{}gmxs
           if $config{trim};
         return $retval;
      }
   );
} ## end sub file

sub intersect {
   my ($l, $r) = @_;
   my ($lh, $rh);
   return App::Sets::Iterator->new(
      sub {
         while ('necessary') {
            $lh //= $l->drop() // last;
            $rh //= $r->drop() // last;
            if ($lh eq $rh) {
               my $retval = $lh;
               $lh = $rh = undef;
               return $retval;
            }
            elsif ($lh gt $rh) {
               $rh = undef;
            }
            else {
               $lh = undef;
            }
         } ## end while ('necessary')
         return undef;
      }
   );
} ## end sub intersect

sub union {
   my ($l, $r) = @_;
   my ($lh, $rh);
   return App::Sets::Iterator->new(
      sub {
         while (defined($lh = $l->head()) && defined($rh = $r->head())) {
            if ($lh eq $rh) {
               $r->drop();
               return $l->drop();
            }
            elsif ($lh lt $rh) {
               return $l->drop();
            }
            else {
               return $r->drop();
            }
         } ## end while (defined($lh = $l->head...
         while (defined($lh = $l->drop())) {
            return $lh;
         }
         while (defined($rh = $r->drop())) {
            return $rh;
         }
         return undef;
      }
   );
} ## end sub union

sub minus {
   my ($l, $r) = @_;
   my ($lh, $rh);
   return App::Sets::Iterator->new(
      sub {
         while (defined($lh = $l->head()) && defined($rh = $r->head())) {
            if ($lh eq $rh) {    # shared, drop both
               $r->drop();
               $l->drop();
            }
            elsif ($lh lt $rh) {    # only in left, OK!
               return $l->drop();
            }
            else {                  # only in right, go on
               $r->drop();
            }
         } ## end while (defined($lh = $l->head...
         return $l->drop();
      }
   );
} ## end sub minus

1;
__END__
