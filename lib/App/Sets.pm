package App::Sets;

# ABSTRACT: set operations in Perl

use strict;
use warnings;
use English qw( -no_match_vars );
use IPC::Open2 qw< open2 >;
use 5.010;
use Getopt::Long
  qw< GetOptionsFromArray :config pass_through no_ignore_case bundling >;
use Pod::Usage qw< pod2usage >;
use Log::Log4perl::Tiny qw< :easy >;

Log::Log4perl->easy_init(
   {
      layout => '[%d] [%-5p] %m%n',
      level  => $INFO,
   }
);

my %config;

sub populate_config {
   my (@args) = @_;

   $config{sorted} = 1                if $ENV{SETS_SORTED};
   $config{trim}   = 1                if $ENV{SETS_TRIM};
   $config{cache}  = $ENV{SETS_CACHE} if exists $ENV{SETS_CACHE};
   GetOptionsFromArray(
      \@args, \%config, qw< man help usage version
        trim|t! sorted|s! cache|cache-sorted|S=s >
     )
     or pod2usage(
      -verbose  => 99,
      -sections => 'USAGE',
     );
   our $VERSION; $VERSION = '0.972' unless defined $VERSION;
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

   my $expression = App::Sets::Parser::parse($input, 0);
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

package App::Sets::Parser;
use strict;
use warnings;
use Carp;
use Log::Log4perl::Tiny qw< :easy >;

=begin grammar

   parse: first
   first:  first  op_difference second | second
   second: second op_union      third  | third
   third:  third  op_intersect  fourth | fourth

   fourth: '(' first ')' | filename

   filename: double_quoted_filename 
           | single_quoted_filename
           | unquoted_filename
   ...

 Left recursion elimination

   first:      second first_tail
   first_tail: <empty> | op_intersect second first_tail

   second:      third second_tail
   second_tail: <empty> | op_union third second_tail

   third:      fourth third_tail
   third_tail: <empty> | op_difference fourth third_tail

=end grammar

=cut

sub parse {
   my ($string) = @_;
   my $retval = first($string, 0);
   my ($expression, $pos) = $retval ? @$retval : (undef, 0);
   return $expression if $pos == length $string;

   my $offending = substr $string, $pos;

   my ($spaces) = $offending =~ s{\A(\s+)}{}mxs;
   $pos += length $spaces;

   my $nchars = 23;
   $offending = substr($offending, 0, $nchars - 3) . '...'
     if length($offending) > $nchars;

   LOGDIE "parse error at char $pos --> $offending\n",;
} ## end sub parse

sub lrx_head {
   my $sequence = _sequence(@_);
   return sub {
      my $retval = $sequence->(@_)
        or return;
      my ($struct, $pos) = @$retval;
      my ($second, $first_tail) = @{$struct}[1, 3];
      if (defined $first_tail->[0]) {
         my ($root, $parent) = @{$first_tail->[0]};
         $parent->[1] = $second->[0];
         $struct = $root;
      }
      else {
         $struct = $second->[0];
      }
      return [$struct, $pos];
     }
} ## end sub lrx_head

sub lrx_tail {
   my $sequence = _sequence('optws', _alternation(_sequence(@_), 'empty'));
   return sub {
      my $retval = $sequence->(@_)
        or return;
      my ($struct, $pos) = @$retval;
      $retval = $struct->[1];
      if (!defined $retval->[0]) {
         $retval = undef;
      }
      else {    # not empty
         my ($op, $second, $tail) = @{$retval->[0]}[0, 2, 4];
         my $node = [$op->[0], undef, $second->[0]];
         if (defined $tail->[0]) {
            my ($root, $parent) = @{$tail->[0]};
            $parent->[1] = $node;    # link leaf to parent node
            $retval = [$root, $node];
         }
         else {
            $retval = [$node, $node];
         }
      } ## end else [ if (!defined $retval->...
      return [$retval, $pos];
     }
} ## end sub lrx_tail

sub first {
   return lrx_head(qw< optws second optws first_tail optws >)->(@_);
}

sub first_tail {
   return lrx_tail(qw< op_subtract optws second optws first_tail optws >)
     ->(@_);
}

sub second {
   return lrx_head(qw< optws third optws second_tail optws >)->(@_);
}

sub second_tail {
   return lrx_tail(qw< op_union optws third optws second_tail optws >)
     ->(@_);
}

sub third {
   return lrx_head(qw< optws fourth optws third_tail optws >)->(@_);
}

sub third_tail {
   return lrx_tail(qw< op_intersect optws fourth optws third_tail optws >)
     ->(@_);
}

sub fourth {
   my $retval = _sequence(
      'optws',
      _alternation(
         _sequence(_string('('), qw< optws first optws >, _string(')')),
         'filename',
      ),
      'optws'
     )->(@_)
     or return;
   my ($struct, $pos) = @$retval;
   my $meat = $struct->[1];
   if (ref($meat->[0])) {
      $retval = $meat->[0][2][0];
   }
   else {
      $retval = $meat->[0];
   }
   return [$retval, $pos];
} ## end sub fourth

sub _op {
   my ($regex, $retval, $string, $pos) = @_;
   pos($string) = $pos;
   return unless $string =~ m{\G($regex)}cgmxs;
   return [$retval, pos($string)];
} ## end sub _op

sub op_intersect {
   return _op(qr{(?:intersect|[iI&^])}, 'intersect', @_);
}

sub op_union {
   return _op(qr{(?:union|[uUvV|+])}, 'union', @_);
}

sub op_subtract {
   return _op(qr{(?:minus|less|[\\-])}, 'minus', @_);
}

sub filename {
   my ($string, $pos) = @_;
   pos($string) = $pos;
   my $retval;
   if (($retval) = $string =~ m{\G ' ( [^']+ ) '}cgmxs) {
      return [$retval, pos($string)];
   }
   elsif (($retval) = $string =~ m{\G " ( (?: \\. | [^"])+ ) "}cgmxs) {
      $retval =~ s{\\(.)}{$1}gmxs;
      return [$retval, pos($string)];
   }
   elsif (($retval) = $string =~ m{\G ( (?: \\. | [\w.-])+ )}cgmxs) {
      $retval =~ s{\\(.)}{$1}gmxs;
      return [$retval, pos($string)];
   }
   return;
} ## end sub filename

sub empty {
   my ($string, $pos) = @_;
   return [undef, $pos];
}

sub is_empty {
   my ($struct) = @_;
   return @{$struct->[0]} > 0;
}

sub ws {
   my ($string, $pos) = @_;
   pos($string) = $pos;
   my ($retval) = $string =~ m{\G (\s+)}cgmxs
     or return;
   return [$retval, pos($string)];
} ## end sub ws

sub optws {
   my ($string, $pos) = @_;
   pos($string) = $pos;
   my ($retval) = $string =~ m{\G (\s*)}cgmxs;
   $retval = [$retval || '', pos($string)];
   return $retval;
} ## end sub optws

sub _string {
   my ($target) = @_;
   my $len = length $target;
   return sub {
      my ($string, $pos) = @_;
      return unless substr($string, $pos, $len) eq $target;
      return [$target, $pos + $len];
     }
} ## end sub _string

sub _alternation {
   my @subs = _resolve(@_);
   return sub {
      my ($string, $pos) = @_;
      for my $sub (@subs) {
         my $retval = $sub->($string, $pos) || next;
         return $retval;
      }
      return;
   };
} ## end sub _alternation

sub _sequence {
   my @subs = _resolve(@_);
   return sub {
      my ($string, $pos) = @_;
      my @chunks;
      for my $sub (@subs) {
         my $chunk = $sub->($string, $pos)
           or return;
         push @chunks, $chunk;
         $pos = $chunk->[1];
      } ## end for my $sub (@subs)
      return [\@chunks, $pos];
   };
} ## end sub _sequence

sub _resolve {
   return
     map { ref $_ ? $_ : __PACKAGE__->can($_) || LOGDIE "unknown $_" } @_;
}

package App::Sets::Iterator;
use strict;
use warnings;

sub new {
   my ($package, $it) = @_;
   return bless {it => $it}, $package;
}

sub head {
   my ($self) = @_;
   return exists $self->{head} ? $self->{head} : $self->next();
}

sub next {
   my ($self) = @_;
   return $self->{head} = $self->{it}->();
}

sub drop {
   my ($self) = @_;
   my $retval = $self->head();
   $self->next();
   return $retval;
} ## end sub drop

1;
__END__
