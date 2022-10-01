#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Encode;
use File::Basename;
use File::Temp qw/tempfile tempdir/;
use File::Spec::Functions;

my %rmd_render_option = (
    pdf      => { out => "rmarkdown::pdf_document", ext => "pdf"},
    pdfbook  => { out => "bookdown::pdf_document2", ext => "pdf"},
    odt      => { out => "rmarkdown::odt_document", ext => "odt"},
    docx     => { out => "officedown::rdocx_document",
                  opt => [ qq/tables = list(caption = list(pre = 'Table:', sep = '  '))/, 
                           qq/plots  = list(caption = list(pre = 'Figure:', sep = '  '))/, ],
                  ext => "docx", },
    docxbook => { out => "bookdwon::word_document2", ext => "docx", },
    pptx     => { out => "officedown::rpptx_document",
                  opt => [ qq/base_format = 'rmarkdown::powerpoint_presentation'/, 
                           qq/toc = TRUE/,
                           qq/toc_depth = 1/,
                           qq/slide_level = 2/, ], },
    beamer   => { out => "rmarkdown::beamer_presentation",
                  opt => [ qq/slide_level = 2/, ],
                  to  => "beamer",
                  ext => "pdf", },
    html     => { out => "rmarkdown::html_document", ext => "html", opt => []},
    htmlbook => { out => "bookdown::html_document2", ext => "html", opt => []},
);

sub pandoc_lua_filter_from_r {
    my $Rlib = qx{Rscript --no-save --no-restore -e 'cat(.libPaths()[1])'};
    my @filter = map {$Rlib . $_} (
        "/bookdown/rmarkdown/lua/custom-environment.lua",
        "/rmarkdown/rmarkdown/lua/pagebreak.lua",
        "/rmarkdown/rmarkdown/lua/latex-div.lua", 
    );
    return @filter;
}

sub rmd2md {
    my ($infile, $to, $md_contents, $pandoc_options, $logfile) = @_;
    # $infile, 待转换的原文件
    # $to，转换的目标格式
    # $md_contest, markdown 文件的内容，列表引用格式
    # $pandoc_options, pandoc 选项，列表引用格式

    my $R_CMD     = "Rscript --no-init-file --no-save --no-restore --verbose";
    my $R_CONFIG  = qq{
        options(box.path = file.path(Sys.getenv('HOME'), 'Repositories',
                                     'R-script', 'box'))
    };
    my $basename  = fileparse($infile, qr/\.[Rr](md|markdown)/);
    my $tdir      = tempdir();
    my %rmd       = %{$rmd_render_option{$to}};
    $rmd{opt}     = defined($rmd{opt}) ? join(", ", @{$rmd{opt}}) : "";
    my $cmd       = qq{rmarkdown::render('$infile',
                                         output_format     = $rmd{out}($rmd{opt}),
                                         intermediates_dir = '$tdir',
                                         quiet             = TRUE,
                                         run_pandoc        = FALSE) };
    my $outfile = catfile($tdir, $basename . ".knit.md");

    system(qq{$R_CMD -e "$R_CONFIG $cmd" >>$logfile 2>>$logfile});
    open my $md_fh, "<", $outfile or die "Cannot open rmarkdown output: $!";
    @{$md_contents} = <$md_fh>;
    close $md_fh;
    unlink $outfile;
    rmdir $tdir;

    push @{$pandoc_options}, map {'--lua-filter="' . $_ . '"'} pandoc_lua_filter_from_r;
    push @{$pandoc_options}, "--variable=graphics";
    return %rmd;
}


