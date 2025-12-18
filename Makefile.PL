use strict;
use warnings;
use ExtUtils::MakeMaker;
use File::ShareDir::Install;

install_share dist => 'share';

WriteMakefile(
  NAME               => 'fexport',
  AUTHOR             => 'liubianshi',
  VERSION_FROM       => 'lib/Fexport.pm',
  ABSTRACT           => 'Export Rmarkdown/Quarto to various formats',
  LICENSE            => 'perl_5',
  PL_FILES           => {},
  MIN_PERL_VERSION   => '5.020',
  CONFIGURE_REQUIRES => {
    'ExtUtils::MakeMaker'     => '0',
    'File::ShareDir::Install' => '0.06',
  },
  BUILD_REQUIRES => {
    'Test::More' => '0',
  },
  PREREQ_PM => {
    'Scope::Guard'     => '0',
    'YAML'             => '0',
    'IPC::Run3'        => '0',
    'Data::Dump'       => '0',
    'File::ShareDir'   => '0',
    'Hash::Merge'      => '0',
    'Text::ParseWords' => '0',
    'Const::Fast'      => '0',
    'Archive::Zip'     => '0',
    'XML::LibXML'      => '0',
    'Mojolicious'      => '0',
    'List::Util'       => '1.45',
    'Getopt::Long'     => '0',
    'Pod::Usage'       => '0',
  },
  TEST_REQUIRES => {
    'Test::More' => '0',
  },
  EXE_FILES => ['script/fexport'],
  dist      => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
  clean     => { FILES    => 'rmd-*' },
);

package MY;
use File::ShareDir::Install qw(postamble);
