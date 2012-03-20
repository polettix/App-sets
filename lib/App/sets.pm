package App::sets;

# ABSTRACT: set operations in Perl
our $VERSION = '0.972';

use strict;
use warnings;
use English qw( -no_match_vars );
use IPC::Open2 qw< open2 >;
use 5.010;
use Getopt::Long qw< GetOptionsFromArray :config pass_through no_ignore_case bundling >;
use Pod::Usage qw< pod2usage >;
use Log::Log4perl::Tiny qw< :easy >;

Log::Log4perl->easy_init({
   layout => '[%d] [%-5p] %m%n',
   level => $INFO,
});

my %config;

sub populate_config {
   my (@args) = @_;

   $config{sorted} = 1 if $ENV{SETS_SORTED};
   $config{trim}   = 1 if $ENV{SETS_TRIM};
   $config{cache}  = $ENV{SETS_CACHE} if exists $ENV{SETS_CACHE};
   GetOptionsFromArray(\@args, \%config, qw< man help usage version
      trim|t! sorted|s! cache|cache-sorted|S=s >)
         or pod2usage(-verbose => 99, -sections => 'USAGE');
   pod2usage(message => "$0 $VERSION", -verbose => 99, -sections => ' ') if $config{version};
   pod2usage(-input => __FILE__, -verbose => 99, -sections => 'USAGE') if $config{usage};
   pod2usage(-input => __FILE__, -verbose => 99, -sections => 'USAGE|EXAMPLES|OPTIONS') if $config{help};
   pod2usage(-input => __FILE__, -verbose => 2) if $config{man};

   $config{cache} = '.sorted' if exists $config{cache} && ! (defined($config{cache}) && length($config{cache}));
   $config{sorted} = 1 if exists $config{cache};

   if (exists $config{cache}) {
      INFO "using sort cache or generating it when not available";
   }
   elsif ($config{sorted}) {
      INFO "assuming input files are sorted";
   }
   INFO "trimming away leading/trailing whitespaces"
      if $config{trim};

   return @args;
}

sub run {
   my $package = shift;
   my @args = populate_config(@_);

   my $input;
   if (@args > 1) {
      shift @args if $args[0] eq '--';
      die "only file op file [op file...] with multiple parameters (@args)...\n"
         unless @args % 2;
      my @chunks;
      while (@args) {
         push @chunks, escape(shift @args);
         push @chunks, shift @args if @args;
      }
      $input = join ' ', @chunks;
   }
   else {
      $input = shift @args;
   }

   my $expression = App::sets::Parser::parse($input, 0);
   my $it = expression($expression);
   while (defined (my $item = $it->drop())) {
      print $item;
      print "\n" if $config{trim};
   }
   return;
}

sub escape {
   my ($text) = @_;
   $text =~ s{(\W)}{\\$1}gmxs;
   return $text;
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

sub _sort_filehandle {
   my ($filename) = @_;
   open my $fh, '-|', 'sort', '-u', $filename
      or die "open() sort -u '$filename': $OS_ERROR";
   return $fh;
}

sub file {
   my ($filename) = @_;
   die "invalid file '$filename'\n" unless -r $filename && ! -d $filename; 

   if ($config{cache}) {
      my $cache_filename = $filename . $config{cache};
      if (! -e $cache_filename) { # generate cache file
         WARN "generating cached sorted file '$cache_filename', might wait a bit...";
         my $ifh = _sort_filehandle($filename);
         open my $ofh, '>', $cache_filename
            or die "open('$cache_filename') for output: $OS_ERROR";
         while (<$ifh>) {
            print {$ofh} $_;
         }
         close $ofh or die "close('$cache_filename'): $OS_ERROR";
      }
      INFO "using '$cache_filename' (assumed to be sorted) instead of '$filename'";
      $filename = $cache_filename;
   }

   my $fh;
   if ($config{sorted}) {
      INFO "opening '$filename', assuming it is already sorted"
         unless $config{cache};
      open $fh, '<', $filename
         or die "open('$filename'): $OS_ERROR";
   }
   else {
      INFO "opening '$filename' and sorting on the fly";
      $fh = _sort_filehandle($filename);
   }
   return App::sets::Iterator->new(
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
   my ($expression, $pos) = $retval ? @$retval : (undef, 0);
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

sub filename {
   my ($string, $pos) = @_;
   pos($string) = $pos;
   my $retval;
   if (($retval) = $string =~ m{\G ' ( [^']+ ) '}cgmxs) {
      return [ $retval, pos($string) ];
   }
   elsif (($retval) = $string =~ m{\G " ( (?: \\. | [^"])+ ) "}cgmxs) {
      $retval =~ s{\\(.)}{$1}gmxs;
      return [ $retval, pos($string) ];
   }
   elsif (($retval) = $string =~ m{\G ( (?: \\. | [\w.-])+ )}cgmxs) {
      $retval =~ s{\\(.)}{$1}gmxs;
      return [ $retval, pos($string) ];
   }
   return;
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

=head1 NAME

sets - set operations in Perl

=head1 USAGE

   sets [--usage] [--help] [--man] [--version]

   sets [--cache-sorted|-S <suffix>] [--sorted|-s] [--trim|-t] expression...

=head1 EXAMPLES

   # intersect two files
   sets file1 ^ file2

   # things are speedier when files are sorted
   sets -s sorted-file1 ^ sorted-file2

   # you can use a bit caching in case, generating sorted files
   # automatically for possible multiple or later reuse. For example,
   # the following is the symmetric difference where the sorting of
   # the input files will be performed two times only
   sets -S .sorted '(file2 ^ file1) + (file2 - file1)'

   # In the example above, note that expressions with grouping need to be
   # specified in a single string.

   # sometimes leading and trailing whitespaces only lead to trouble, so
   # you can trim data on-the-fly
   sets -t file1-unix - file2-dos

=head1 DESCRIPTION

This program lets you perform set operations working on input files.

The set operations that can be performed are the following:

=over

=item B<< intersection >>

the binary operation that selects all the elements that are in both
the left and the right hand operand. This operation can be specified with
any of the following operators:

=over

=item B<< intersect >>

=item B<< i >>

=item B<< I >>

=item B<< & >>

=item B<< ^ >>

=back

=item B<< union >>

the binary operation that selects all the elements that are in either
the left or the right hand operand. This operation can be specified with
any of the following operators:

=over

=item B<< union >>

=item B<< u >>

=item B<< U >>

=item B<< v >>

=item B<< V >>

=item B<< | >>

=item B<< + >>

=back

=item B<< difference >>

the binary operation that selects all the elements that are in
the left but not in the right hand operand. This operation can be
specified with any of the following operators:

=over

=item B<< minus >>

=item B<< less >>

=item B<< \ >>

=item B<< - >>

=back

=back


Expressions can be grouped with parentheses, so that you can set the
precedence of the operations and create complex aggregations. For
example, the following expression computes the symmetric difference
between the two sets:

   (set1 - set2) + (set2 - set1)

Expressions should be normally entered as a single string that is then
parsed. In case of I<simple> operations (e.g. one operation on two
sets) you can also provide multiple arguments. In other terms, the
following invocations should be equivalent:

   sets 'set1 - set2'
   sets set1 - set2

Options can be specified only as the first parameters. If your first
set begins with a dash, use a double dash to explicitly terminate the
list of options, e.g.:

   sets -- -first-set ^ -second-set

In general, anyway, the first non-option argument terminates the list
of options as well, so the example above would work also without the
C<-->. In the pathological case that your file is named C<-s>, anyway,
you would need the explicit termination of options with C<-->. You get
the idea.

Files with spaces and other weird stuff can be specified by means
of quotes or escapes. The following are all valid methods of subtracting
C<to remove> from C<input file>:

   sets "'input file' - 'to remove'"
   sets '"input file" - "to remove"'
   sets 'input\ file - to\ remove'
   sets "input\\ file - to\\ remove"
   sets input\ file - to\ remove

The first two examples use single and double quoting. The third example
uses a backslash to escape the spaces, as well as the fourth example in
which the escape character is repeated due to the interpolation rules
of the shell. The last example leverages upon the shell rules for
escaping AND the fact that simple expressions like that can be specified
as multiple arguments instead of a single string.

=head1 OPTIONS

=over

=item --cache-sorted | -S I<suffix>

input files are sorted and saved into a file with the same name and the
I<suffix> appended, so that if this file exists it is used instead of
the input file. In this way it is possible to generate sorted files on
the fly and reuse them if available. For example, suppose that you want
to remove the items in C<removeme> from files C<file1> and C<file2>; in
the following invocations:

   sets file1 - removeme > file1.filtered
   sets file2 - removeme > file2.filtered

we have that file C<removeme> would be sorted in both calls, while in the
following ones:

   sets -S .sorted file1 - removeme > file1.filtered
   sets -S .sorted file2 - removeme > file2.filtered

it would be sorted only in the first call, that generates C<removeme.sorted>
that is then reused by the second call. Of course you're trading disk space
for speed here, but most of the times it is exactly what you want to do when
you have disk space but little time to wait. This means that most of the
times you'll e wanting to use this option, I<unless> you're willing to wait
more or you already know that input files are sorted (in which case you would
use L</"--sorted | -s"> instead).

=item --help

print a somewhat more verbose help, showing usage, this description of
the options and some examples from the synopsis.

=item --man

print out the full documentation for the script.

=item --sorted | -s

in normal mode, input files are sorted on the fly before being used. If you
know that I<all> your input files are already sorted, you can spare the
extra sorting operation by using this option:

   sets -s file1.sorted ^ file2.sorted

=item --trim | -t

if you happen to have leading and/or trailing white spaces (including
tabs, carriage returns, etc.) that you want to get rid of, you can turn
this option on. This is particularly useful if some files come from the
UNIX world and other ones from the DOS world, becaue they have different
ideas about terminating a line.

=item --usage

print a concise usage line and exit.

=item --version

print the version of the script.

=back

=head1 ENVIRONMENT

Some options can be set from the environment:

=over

=item C<SETS_CACHE>

the same as specifying C<< --cache-sorted | -S I<suffix> >> on the command line. The
contents of C<SETS_CACHE> is used as the I<suffix>.

=item C<SETS_SORTED>

the same as specifying C<--sorted | -s> on the command line

=item C<SETS_TRIM>

the same as specifying C<--trim | -t> on the command line

=back

=head1 AUTHOR

Flavio Poletti C<polettix@cpan.org>

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2012, Flavio Poletti C<polettix@cpan.org>. All rights reserved.

This script is free software; you can redistribute it and/or
modify it under the terms of the Artistic License 2.0 - see
L<http://www.perlfoundation.org/artistic_license_2_0> for details.

This program is distributed in the hope that it will be useful,
but without any warranty; without even the implied warranty of
merchantability or fitness for a particular purpose.

=cut
