package Fexport::Util;
use strict;
use warnings;
use v5.20;
use Exporter 'import';

our @EXPORT_OK = qw(md2array md2file write2file pandoc_opts_default get_resource_path);

use File::Spec;
use File::ShareDir qw(dist_file);
use FindBin qw($RealBin);
use Fatal qw(open close);

sub md2array {
  my ( $in_contents, $out_contents, $pandoc, $outfile, $log_fh ) = @_;
  md2file( $in_contents, $pandoc, $log_fh );
  open my $read_content, "<", $outfile
    or die "cannot open file $outfile: $!";
  @{$out_contents} = <$read_content>;
  close $read_content;
}

sub md2file {
  my ( $in_contents, $pandoc, $log_fh ) = @_;
  say {$log_fh} join " ", @{$pandoc};
  open my $pandoc_fh, "|-", join( " ", @{$pandoc} )
    or die "cannot run pandoc: $!\n";
  print {$pandoc_fh} join "", @{$in_contents};
  close $pandoc_fh;
}

sub write2file {
  my ( $content, $outfile ) = @_;
  open my $fh, ">", $outfile or die "cannot open $outfile: $!";
  print $fh $_ for ( @{$content} );
  close $fh;
}

sub pandoc_opts_default {
  my $to = shift;
  my ( $datadir, $defaults, $defaultfile );
  $datadir = qx[pandoc --version | grep -E '^User data'];
  $datadir =~ s/^.*\s*User data directory:\s*([^\s]+)\n/$1/;
  $defaultfile = File::Spec->catfile( $datadir, "defaults", "2$to.yaml" );
  $defaults    = "-d2$to" if -f $defaultfile;
  if ( qx/uname/ =~ m/^Darwin/ ) {
    $defaultfile = File::Spec->catfile( $datadir, "defaults", "2${to}_mac.yaml" );
    $defaults    = "-d2${to}_mac" if -f $defaultfile;
  }
  return ( $defaults // "" );
}

sub get_resource_path {
  my $filename = shift;
  # Check local development path (repo structure: script/ and share/)
  my $local_path = File::Spec->catfile($RealBin, "..", "share", $filename);
  if (-e $local_path) {
    return $local_path;
  }
  
  my $path;
  eval {
    $path = dist_file('fexport', $filename);
  };
  if ($@ or !defined $path or !-e $path) {
    # Last ditch effort: look in the same directory as script (legacy/flat)
    $path = File::Spec->catfile($RealBin, $filename);
  }
  
  if (!-e $path) {
     warn "Warning: Resource file '$filename' not found in share directory or local path.\n";
  }
  return $path;
}

1;
