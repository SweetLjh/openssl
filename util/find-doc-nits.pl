#! /usr/bin/env perl
# Copyright 2002-2016 The OpenSSL Project Authors. All Rights Reserved.
#
# Licensed under the OpenSSL license (the "License").  You may not use
# this file except in compliance with the License.  You can obtain a copy
# in the file LICENSE in the source distribution or at
# https://www.openssl.org/source/license.html


require 5.10.0;
use warnings;
use strict;
use Pod::Checker;
use File::Find;
use File::Basename;
use File::Spec::Functions;
use Getopt::Std;
use lib catdir(dirname($0), "perl");
use OpenSSL::Util::Pod;

# Options.
our($opt_s);
our($opt_u);
our($opt_h);
our($opt_n);

sub help()
{
    print <<EOF;
Find small errors (nits) in documentation.  Options:
    -n Print nits in POD pages
    -s Also print missing sections in POD pages (implies -n)
    -u List undocumented functions
    -h Print this help message
EOF
    exit;
}

my $temp = '/tmp/docnits.txt';
my $OUT;

my %mandatory_sections =
    ( '*'    => [ 'NAME', 'DESCRIPTION', 'COPYRIGHT' ],
      1      => [ 'SYNOPSIS', '(COMMAND\s+)?OPTIONS' ],
      3      => [ 'SYNOPSIS', 'RETURN\s+VALUES' ],
      5      => [ ],
      7      => [ ] );

# Cross-check functions in the NAME and SYNOPSIS section.
sub name_synopsis()
{
    my $id = shift;
    my $filename = shift;
    my $contents = shift;

    # Get NAME section and all words in it.
    return unless $contents =~ /=head1 NAME(.*)=head1 SYNOPSIS/ms;
    my $tmp = $1;
    $tmp =~ tr/\n/ /;
    $tmp =~ s/-.*//g;
    $tmp =~ s/,//g;

    my $dirname = dirname($filename);
    my $simplename = basename($filename);
    $simplename =~ s/.pod$//;
    my $foundfilename = 0;
    my %foundfilenames = ();
    my %names;
    foreach my $n ( split ' ', $tmp ) {
        $names{$n} = 1;
        $foundfilename++ if $n eq $simplename;
        $foundfilenames{$n} = 1
            if -f "$dirname/$n.pod" && $n ne $simplename;
    }
    print "$id the following exist as other .pod files:\n",
        join(" ", sort keys %foundfilenames), "\n"
        if %foundfilenames;
    print "$id $simplename (filename) missing from NAME section\n",
        unless $foundfilename;

    # Find all functions in SYNOPSIS
    return unless $contents =~ /=head1 SYNOPSIS(.*)=head1 DESCRIPTION/ms;
    my $syn = $1;
    foreach my $line ( split /\n+/, $syn ) {
        my $sym;
        $line =~ s/STACK_OF\([^)]+\)/int/g;
        $line =~ s/__declspec\([^)]+\)//;
        if ( $line =~ /typedef.* (\S+);/ ) {
            $sym = $1;
        } elsif ( $line =~ /#define ([A-Za-z0-9_]+)/ ) {
            $sym = $1;
        } elsif ( $line =~ /([A-Za-z0-9_]+)\(/ ) {
            $sym = $1;
        }
        else {
            next;
        }
        print "$id $sym missing from NAME section\n"
            unless defined $names{$sym};
        $names{$sym} = 2;

        # Do some sanity checks on the prototype.
        print "$id prototype missing spaces around commas: $line\n"
            if ( $line =~ /[a-z0-9],[^ ]/ );
    }

    foreach my $n ( keys %names ) {
        next if $names{$n} == 2;
        print "$id $n missing from SYNOPSIS\n";
    }
}

sub check()
{
    my $filename = shift;
    my $dirname = basename(dirname($filename));

    my $contents = '';
    {
        local $/ = undef;
        open POD, $filename or die "Couldn't open $filename, $!";
        $contents = <POD>;
        close POD;
    }

    my $id = "${filename}:1:";

    &name_synopsis($id, $filename, $contents)
        unless $contents =~ /=for comment generic/
            or $filename =~ m@man[157]/@;

    print "$id doesn't start with =pod\n"
        if $contents !~ /^=pod/;
    print "$id doesn't end with =cut\n"
        if $contents !~ /=cut\n$/;
    print "$id more than one cut line.\n"
        if $contents =~ /=cut.*=cut/ms;
    print "$id missing copyright\n"
        if $contents !~ /Copyright .* The OpenSSL Project Authors/;
    print "$id copyright not last\n"
        if $contents =~ /head1 COPYRIGHT.*=head/ms;
    print "$id head2 in All uppercase\n"
        if $contents =~ /head2\s+[A-Z ]+\n/;
    print "$id extra space after head\n"
        if $contents =~ /=head\d\s\s+/;
    print "$id period in NAME section\n"
        if $contents =~ /=head1 NAME.*\.\n.*=head1 SYNOPSIS/ms;
    print "$id POD markup in NAME section\n"
        if $contents =~ /=head1 NAME.*[<>].*=head1 SYNOPSIS/ms;

    # Look for multiple consecutive openssl #include lines.
    # Consecutive because of files like md5.pod. Sometimes it's okay
    # or necessary, as in ssl/SSL_set1_host.pod
    if ( $contents !~ /=for comment multiple includes/ ) {
        if ( $contents =~ /=head1 SYNOPSIS(.*)=head1 DESCRIPTION/ms ) {
            my $count = 0;
            foreach my $line ( split /\n+/, $1 ) {
                if ( $line =~ m@include <openssl/@ ) {
                    if ( ++$count == 2 ) {
                        print "$id has multiple includes\n";
                    }
                } else {
                    $count = 0;
                }
            }
        }
    }

    return unless $opt_s;

    # Find what section this page is in.  If run from "." assume
    # section 3.
    my $section = 3;
    $section = $1 if $dirname =~ /man([1-9])/;

    foreach ((@{$mandatory_sections{'*'}}, @{$mandatory_sections{$section}})) {
        print "$id doesn't have a head1 section matching $_\n"
            if $contents !~ /^=head1\s+${_}\s*$/m;
    }

    open my $OUT, '>', $temp
        or die "Can't open $temp, $!";
    podchecker($filename, $OUT);
    close $OUT;
    open $OUT, '<', $temp
        or die "Can't read $temp, $!";
    while ( <$OUT> ) {
        next if /\(section\) in.*deprecated/;
        print;
    }
    close $OUT;
    unlink $temp || warn "Can't remove $temp, $!";
}

my %dups;

sub parsenum()
{
    my $file = shift;
    my @apis;

    open my $IN, '<', $file
        or die "Can't open $file, $!, stopped";

    while ( <$IN> ) {
        next if /\bNOEXIST\b/;
        next if /\bEXPORT_VAR_AS_FUNC\b/;
        push @apis, $1 if /([^\s]+).\s/;
    }

    close $IN;

    print "# Found ", scalar(@apis), " in $file\n";
    return sort @apis;
}

sub getdocced()
{
    my $dir = shift;
    my %return;

    foreach my $pod ( glob("$dir/*.pod") ) {
        my %podinfo = extract_pod_info($pod);
        foreach my $n ( @{$podinfo{names}} ) {
            $return{$n} = $pod;
            print "# Duplicate $n in $pod and $dups{$n}\n"
                if defined $dups{$n} && $dups{$n} ne $pod;
            $dups{$n} = $pod;
        }
    }

    return %return;
}

my %docced;

sub printem()
{
    my $libname = shift;
    my $numfile = shift;
    my $count = 0;

    foreach my $func ( &parsenum($numfile) ) {
        next if $docced{$func};

        # Skip ASN1 utilities
        next if $func =~ /^ASN1_/;

        print "$libname:$func\n";
        $count++;
    }
    print "# Found $count missing from $numfile\n\n";
}


getopts('nshu');

&help() if ( $opt_h );

if ( $opt_n or $opt_s ) {
    foreach (@ARGV ? @ARGV : glob('doc/*/*.pod')) {
        &check($_);
    }
}
if ( $opt_u ) {
    my %temp = &getdocced('doc/man3');
    foreach ( keys %temp ) {
        $docced{$_} = $temp{$_};
    }
    &printem('crypto', 'util/libcrypto.num');
    &printem('ssl', 'util/libssl.num');
}

exit;
