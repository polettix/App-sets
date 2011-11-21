package App::sets;

# ABSTRACT: set operations in Perl

use strict;
use warnings;
use English qw( -no_match_vars );
use IPC::Open2 qw< open2 >;
use 5.010;
use Data::Dumper;

sub run {
   my ($package, $input) = @_;
   my $expression = App::sets::Parser::parse($input, 0);
   my $it = expression($expression);
   while (defined (my $item = $it->drop())) {
      print $item;
   }
   return;
}

sub expression {
   my ($expression) = @_;
   if (ref $expression) { # operation
      my ($op, $l, $r) = @$expression;
      return __PACKAGE__->can($op)->(expression($l), expression($r));
   }
   else { # plain file
      return file($expression);
   }
}

sub file {
   my ($filename) = @_;
   die "invalid file '$filename'\n" unless -r $filename && ! -d $filename; 
   open my $fh, '-|', 'sort', '-u', $filename
     or die "open('$filename'): $OS_ERROR";
   return App::sets::Iterator->new(
      sub {
         scalar readline $fh;
      }
   );
} ## end sub file

sub intersect {
   my ($l, $r) = @_;
   my ($lh, $rh);
   return App::sets::Iterator->new(
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
   return App::sets::Iterator->new(
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
         }
         while (defined($lh = $l->drop())) {
            return $lh;
         }
         while (defined($rh = $r->drop())) {
            return $rh;
         }
         return undef;
      }
   );
}

sub minus {
   my ($l, $r) = @_;
   my ($lh, $rh);
   return App::sets::Iterator->new(
      sub {
         while (defined($lh = $l->head()) && defined($rh = $r->head())) {
            if ($lh eq $rh) { # shared, drop both
               $r->drop();
               $l->drop();
            }
            elsif ($lh lt $rh) {  # only in left, OK!
               return $l->drop();
            }
            else {                # only in right, go on
               $r->drop();
            }
         }
         return $l->drop();
      }
   );
}

package App::sets::Parser;
use strict;
use warnings;
use Carp;

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
   my ($expression, $pos) = @$retval;
   return $expression if $pos == length $string;

   my $offending = substr $string, $pos;

   my ($spaces) = $offending =~ s{\A(\s+)}{}mxs;
   $pos += length $spaces;

   my $nchars = 23;
   $offending = substr($offending, 0, $nchars - 3) . '...'
      if length($offending) > $nchars;

   die "parse error at char $pos --> $offending\n",
}

sub lrx_head {
   my $sequence = _sequence(@_);
   return sub {
      my $retval = $sequence->(@_)
         or return;
      my ($struct, $pos) = @$retval;
      my ($second, $first_tail) = @{$struct}[1,3];
      if (defined $first_tail->[0]) {
         my ($root, $parent) = @{$first_tail->[0]};
         $parent->[1] = $second->[0];
         $struct = $root;
      }
      else {
         $struct = $second->[0];
      }
      return [ $struct, $pos ];
   }
}

sub lrx_tail {
   my $sequence = _sequence('optws', _alternation(_sequence(@_), 'empty'));
   return sub {
      my $retval = $sequence->(@_) 
         or return;
      my ($struct, $pos) = @$retval;
      $retval = $struct->[1];
      if (! defined $retval->[0]) {
         $retval = undef;
      }
      else { # not empty
         my ($op, $second, $tail) = @{$retval->[0]}[0,2,4];
         my $node = [ $op->[0], undef, $second->[0] ];
         if (defined $tail->[0]) {
            my ($root, $parent) = @{$tail->[0]};
            $parent->[1] = $node; # link leaf to parent node
            $retval = [ $root, $node ];
         }
         else {
            $retval = [ $node, $node ];
         }
      }
      return [$retval, $pos];
   }
}


sub first {
   return lrx_head(qw< optws second optws first_tail optws >)->(@_);
}
sub first_tail {
   return lrx_tail(qw< op_subtract optws second optws first_tail optws >)->(@_);
}

sub second {
   return lrx_head(qw< optws third optws second_tail optws >)->(@_);
}
sub second_tail {
   return lrx_tail(qw< op_union optws third optws second_tail optws >)->(@_);
}

sub third {
   return lrx_head(qw< optws fourth optws third_tail optws >)->(@_);
}
sub third_tail {
   return lrx_tail(qw< op_intersect optws fourth optws third_tail optws >)->(@_);
}


sub _op {
   my ($regex, $retval, $string, $pos) = @_;
   pos($string) = $pos;
   return unless $string =~ m{\G($regex)}cgmxs;
   return [ $retval, pos($string) ];
}
sub op_intersect {
   return _op(qr{(?:intersect|[iI&^])}, 'intersect', @_);
}
sub op_union {
   return _op(qr{(?:union|[uUvV|+])}, 'union', @_);
}
sub op_subtract {
   return _op(qr{(?:minus|less|[\\-])}, 'minus', @_);
}

sub fourth {
   my $retval = _sequence('optws', _alternation(
      _sequence(_string('('), qw< optws first optws >, _string(')')),
      'filename',
   ), 'optws')->(@_) or return;
   my ($struct, $pos) = @$retval;
   my $meat = $struct->[1];
   if (ref($meat->[0])) {
      $retval = $meat->[0][2][0];
   }
   else {
      $retval = $meat->[0];
   }
   return [ $retval, $pos ];
}


sub empty {
   my ($string, $pos) = @_;
   return [ undef, $pos ];
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
}

sub optws {
   my ($string, $pos) = @_;
   pos($string) = $pos;
   my ($retval) = $string =~ m{\G (\s*)}cgmxs;
   $retval = [$retval || '', pos($string)];
   return $retval;
}

sub _string {
   my ($target) = @_;
   my $len = length $target;
   return sub {
      my ($string, $pos) = @_;
      return unless substr($string, $pos, $len) eq $target;
      return [ $target, $pos + $len ];
   }
}

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
}

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
      }
      return [ \@chunks, $pos ];
   };
}

sub _resolve {
   return map { ref $_ ? $_ : __PACKAGE__->can($_) || die "unknown $_" } @_;
}

sub _optional {
   my ($element) = _resolve(@_);
   return sub {
      my ($string, $pos) = @_;
      return $element->($string, $pos) || [ '', $pos ];
   };
}

sub filename {
   my $retval = _alternation(qw<
      singlequoted_filename
      doublequoted_filename
      unquoted_filename
   >)->(@_) or return;
   return $retval;
   return [ [ filename => $retval->[0] ], $retval->[1] ];
}

sub singlequoted_filename {
   my ($string, $pos) = @_;
   pos($string) = $pos;
   my ($retval) = $string =~ m{\G '( [^']+ )' }cgmxs
      or return;
   return [$retval, pos($string)];
}

sub doublequoted_filename {
   my ($string, $pos) = @_;
   pos($string) = $pos;
   my ($retval) = $string =~ m{\G "( (?: \\. | [^"])+ )" }cgmxs
      or return;
   $retval =~ s{\\(.)}{$1}gmxs;
   return [$retval, pos($string)];
}

sub unquoted_filename {
   my ($string, $pos) = @_;
   pos($string) = $pos;
   my ($retval) = $string =~ m{\G( (?: \\. | \w)+ )}cgmxs
      or return;
   $retval =~ s{\\(.)}{$1}gmxs;
   return [$retval, pos($string)];
}


package App::sets::Iterator;
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
