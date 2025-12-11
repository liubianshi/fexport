use strict;
use warnings;
use ExtUtils::MakeMaker;
use File::ShareDir::Install;

install_share dist => 'share';

WriteMakefile(
    NAME             => 'fexport',
    AUTHOR           => 'liubianshi', 
    VERSION_FROM     => 'lib/Fexport.pm',
    ABSTRACT         => 'Export Rmarkdown/Quarto to various formats', 
    LICENSE          => 'perl_5',
    PL_FILES         => {},
    MIN_PERL_VERSION => '5.020',
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => '0',
        'File::ShareDir::Install' => '0.06',
    },
    BUILD_REQUIRES => {
        'Test::More' => '0',
    },
    PREREQ_PM => {
        'Scope::Guard' => '0',
        'YAML'         => '0',
        'Data::Dump'   => '0',
        'File::ShareDir' => '0',
    },
    EXE_FILES => [ 'script/fexport' ],
    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean => { FILES => 'rmd-*' },
);

package MY;
use File::ShareDir::Install qw(postamble);
