package HTTP::Cache::Transparent;

use strict;

our $VERSION = '0.4';

=head1 NAME

HTTP::Cache::Transparent - Cache the result of http get-requests persistently.

=head1 SYNOPSIS

  use LWP::Simple;
  use HTTP::Cache::Transparent;

  HTTP::Cache::Transparent::init( {
    BasePath => '/tmp/cache',
  } );

  my $data = get( 'http://www.sn.no' );

=head1 DESCRIPTION

An implementation of http get that keeps a local cache of fetched
pages to avoid fetching the same data from the server if it hasn't
been updated. The cache is stored on disk and is thus persistent
between invocations.

Uses the http-headers If-Modified-Since and ETag to let the server
decide if the version in the cache is up-to-date or not.

The cache is implemented by modifying the LWP::UserAgent class to
seamlessly cache the result of all requests that can be cached.

=head1 INITIALIZING THE CACHE

HTTP::Cache::Transparent provides an init-method that sets the
parameters for the cache and overloads a method in LWP::UserAgent
to activate the cache.After init has been called, the normal 
LWP-methods (LWP::Simple as well as the more full-fledged 
LWP::Request methods) should be used as usual.

=over 4

=cut

use Carp;
use LWP::UserAgent;
use HTTP::Status qw/RC_NOT_MODIFIED RC_OK RC_PARTIAL_CONTENT/;

use Digest::MD5 qw/md5_hex/;
use IO::File;
use File::Copy;
use Cwd;

my $basepath;
my $maxage;
my $verbose;

my $org_simple_request;

=item init

Initialize the HTTP cache. Takes a single parameter which is a 
hashref containing named arguments to the object.

  HTTP::Cache::Transparent::init( { 
    BasePath  => "/tmp/cache", # Directory to store the cache in. 
    MaxAge    => 8*24,         # How many hours should items be
                               # kept in the cache after they 
                               # were last requested?
                               # Default is 8*24.
    Verbose   => 1,            # Print progress-messages to STDERR. 
                               # Default is 0.
   } );

The directory where the cache is stored must be writable. It must also only
contain files created by HTTP::Cache::Transparent.

=cut 

sub init
{
  my( $arg ) = @_;

  exists( $arg->{BasePath} ) 
    or croak( "You must specify a BasePath" ); 

  $basepath = $arg->{BasePath};

  -d $basepath
    or croak( "$basepath is not a directory" ); 

  # Append a trailing slash if it is missing.
  $basepath =~ s%([^/])$%$1/%;

  $maxage = $arg->{MaxAge} || 8*24; 
  $verbose = $arg->{Verbose} || 0;

  # Make sure that LWP::Simple does not use its simplified
  # get-method that bypasses LWP::UserAgent. 
  $LWP::Simple::FULL_LWP++;

  $org_simple_request = \&LWP::UserAgent::simple_request;

  {
    no warnings;
    *LWP::UserAgent::simple_request = \&simple_request_cache
  }
}

=item Initializing from use-line

An alternative way of initializing HTTP::Cache::Transparent is to supply
parameters in the use-line. This allows you to write

  use HTTP::Cache::Transparent ( BasePath => '/tmp/cache' );

which is exactly equivalent to

  use HTTP::Cache::Transparent;
  HTTP::Cache::Transparent::init( BasePath => '/tmp/cache' );

The advantage to using this method is that you can do

  perl -MHTTP::Cache::Transparent=BasePath,/tmp/cache myscript.pl

or even set the environment variable PERL5OPT 
  
  PERL5OPT=-MHTTP::Cache::Transparent=BasePath,/tmp/cache
  myscript.pl

and have all the http-requests performed by myscript.pl go through the
cache without changing myscript.pl

=back

=cut 

sub import
{
  my( $module, %args ) = @_;
  return if (scalar(keys(%args)) == 0);

  HTTP::Cache::Transparent::init( \%args );
}

END
{
  remove_old_entries();
}

sub simple_request_cache
{
  my($self, $r, $content_cb, $read_size_hint) = @_;
  
  my $res;

  print STDERR "Fetching " . $r->uri
    if( $verbose );

  if( $r->method eq "GET" and
      not defined( $r->header( 'If-Modified-Since' ) ) and
      not defined( $content_cb ) )
  {
    my $url = $r->uri->as_string;
    my $key = $url;
    $key .= "\n" . $r->header('Range')
      if defined $r->header('Range');

    my $filename = $basepath . urlhash( $url );
    my $fh;
    my $meta;

    if( -s $filename )
    {
      $fh = new IO::File "< $filename"
        or die "Failed to read from $filename";

      $meta = read_meta( $fh );
      
      if( $meta->{Url} eq $url )
      {
        $meta->{'Range'} = "" 
          unless defined( $meta->{'Range'} );

        # Check that the Range is the same for this request as 
        # for the one in the cache.
        if( (not defined( $r->header( 'Range' ) ) ) or
            $r->header( 'Range' ) eq $meta->{'Range'} )
        {
          $r->header( 'If-Modified-Since', $meta->{'Last-Modified'} )
            if exists( $meta->{'Last-Modified'} );
          
          $r->header( 'ETag', $meta->{ETag} )
            if( exists( $meta->{ETag} ) );
        }
      }
      else
      {
        warn "Cache collision: $url and $meta->{Url} have the same md5sum";
      }
    }

    $res = &$org_simple_request( $self, $r );

    if( $res->code == RC_NOT_MODIFIED )
    {
      print STDERR " from cache.\n" 
        if( $verbose );

      my $content;
      my $buf;
      while ( $fh->read( $buf, 1024 ) > 0 )
      {
        $content .= $buf;
      }
      
      $fh->close();
      
      # Set last-accessed for cache-entry.
      my $mtime = time;
      utime( $mtime, $mtime, $filename );

      # modify response
      if( $HTTP::Message::VERSION >= 1.44 )
      {
        $res->content_ref( \$content );
      }
      else
      {
        $res->content( $content );
      }

      # For HTTP::Cache::Transparent earlier than 0.4,
      # there is no Code in the cache.
      if( defined( $meta->{Code} ) )
      {
        $res->code( $meta->{Code} );
      }
      else
      {
        $res->code( RC_OK );
      }
      
      $res->header( 'Content-Range', $meta->{'Content-Range'} )
        if defined( $meta->{'Content-Range' } );

      $res->header( "X-Cached", 1 );
      $res->header( "X-Content-Unchanged", 1 );
    }
    else
    {
      $fh->close() 
        if defined $fh;;

      if( defined( $meta->{MD5} ) and 
                   md5_hex( $res->content ) eq $meta->{MD5} )
      {
        $res->header( "X-Content-Unchanged", 1 );
        print STDERR " unchanged"
          if( $verbose );
      }

      print STDERR " from server.\n"
        if( $verbose );

      write_cache_entry( $filename, $url, $r, $res )
        if( $res->code == RC_OK or
            $res->code == RC_PARTIAL_CONTENT );
    }
  }
  else
  {
    # We won't try to cache this request. 
    $res =  &$org_simple_request( $self, $r, 
                                  $content_cb, $read_size_hint );
  }

  return $res;
}


# Read metadata and position filehandle at start of data.
sub read_meta
{
  my( $fh ) = @_;
  my %meta;

  my( $key, $value );
  do
  {
    my $line = <$fh>;
    ( $key, $value ) = ($line =~ /(\S+)\s+(.*)[\n\r]*/);

    $meta{$key} = $value
      if( defined $value );

  }
  while( defined( $value ) );

  return \%meta;
}

# Write metadata and position filehandle where data should be written.
sub write_meta
{
  my( $fh, $meta ) = @_;

  foreach my $key (sort keys( %{$meta} ) )
  {
    print $fh "$key $meta->{$key}\n";
  }
  
  print $fh "\n";
}

sub write_cache_entry
{
  my( $filename, $url, $req, $res ) = @_;

  my $out_filename = "$filename.tmp$$";
  my $fh = new IO::File "> $out_filename";

  my $meta;
  $meta->{Url} = $url;
  $meta->{'Last-Modified'} = $res->header('Last-Modified')
    if defined( $res->header('Last-Modified') );
  $meta->{ETag} = $res->header('ETag') 
    if defined( $res->header('ETag') );
  $meta->{MD5} = md5_hex( $res->content );
  $meta->{Range} = $req->header('Range')
    if defined( $req->header('Range') );
  $meta->{Code} = $res->code;
  $meta->{'Content->Range'} = $res->header('Content-Range')
    if defined $res->header('Content-Range');

  write_meta( $fh, $meta );

  print $fh $res->content;
  $fh->close;

  move( $out_filename, $filename );
}

sub urlhash
{
  my( $url ) = @_;

  return md5_hex( $url );
}

sub remove_old_entries
{
  if( defined( $basepath ) )
  {
    my $oldcwd = getcwd();
    chdir( $basepath );

    my @files = glob("*");
    foreach my $file (@files)
    {
      if( $file !~ m%/^[0-9a-f]{32}$% )
      {
        print STDERR "HTTP::Cache::Transparent: Unknown file found in cache directory: $basepath$file\n";
      }
      elsif( (-M($file))*24 > $maxage )
      {
        print STDERR "Deleting $file.\n"
          if( $verbose );
        unlink( $file );
      }
    }

    chdir( $oldcwd );
  }
}

=head1 INSPECTING CACHE BEHAVIOR

The HTTP::Cache::Transparent inserts two special headers in the
HTTP::Response object. These can be accessed via the 
HTTP::Response::header()-method.

=over 4

=item X-Cached

This header is inserted and set to 1 if the response is delivered from 
the cache instead of from the server.

=item X-Content-Unchanged

This header is inserted and set to 1 if the content returned is the same
as the content returned the last time this url was fetched. This header
is always inserted and set to 1 when the response is delivered from 
the cache.

=back

=head1 LIMITATIONS

This module has a number of limitations that you should be aware of
before using it.

=over 4

=item -

There is no upper limit to how much diskspace the cache requires. The
only limiting mechanism is that data for urls that haven't been requested
in the last MaxAge hours will be removed from the cache the next time
the program exits.

=item -

Currently, only get-requests that store the result in memory (i.e. do
not use the option to have the result stored directly in a file or
delivered via a callback) is cached. I intend to remove this limitation
in a future version.

=item -

The support for Ranges is a bit primitive. It creates a new object in
the cache for each unique combination of url and range. This will work ok 
as long as you always request the same range(s) for a url.

=item -

The cache doesn't properly check and store all headers in the HTTP
request and response. Therefore, if you request the same url repeatedly
with different sets of headers (cookies, accept-encoding etc), and these
headers affect the response from the server, the cache may return the
wrong response.
 
=back

=head1 CACHE FORMAT

The cache is stored on disk as one file per cached object. The filename
is equal to the md5sum of the url and the Range-header if it exists.
The file contains a set of 
key/value-pairs with metadata (one entry per line) followed by a blank 
line and then the actual data returned by the server.

The last modified date of the cache file is set to the time when the
cache object was last requested by a user.

=head1 AUTHOR

Mattias Holmlund, E<lt>$firstname -at- $lastname -dot- se<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2004 by Mattias Holmlund

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.4 or,
at your option, any later version of Perl 5 you may have available.


=cut

1;
