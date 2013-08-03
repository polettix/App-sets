NAME
====

App::Sets - set operations in Perl

SYNOPSIS
========

    # intersect two files
    sets file1 ^ file2

    # things are speedier when files are sorted
    sets -s sorted-file1 ^ sorted-file2

    # you can use a bit caching in case, generating sorted files
    # automatically for possible multiple or later reuse. For example,
    # the following is the symmetric difference where the sorting of
    # the input files will be performed two times only
    sets -S .sorted '(file1 - file2) + (file2 - file1)'

    # In the example above, note that expressions with grouping need to be
    # specified in a single string.

    # sometimes leading and trailing whitespaces only lead to trouble, so
    # you can trim data on-the-fly
    sets -t file1-unix - file2-dos


ALL THE REST
============

Want to contribute? [Fork it on GitHub](https://github.com/polettix/App-sets).

[App::Sets is on CPAN](https://metacpan.org/release/App-Sets) as well.

Want just the script, ready to go with batteries included? [Download it
from GitHub](https://raw.github.com/polettix/App-sets/master/sets).

That's all folks!

