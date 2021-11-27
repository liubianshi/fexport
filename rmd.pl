#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Encode;
use File::Basename;
use File::Temp qw/tempfile tempdir/;
use File::Spec::Functions;


my %rmd_render_option = (
    pdf => {
        out => "rmarkdown::pdf_document",
        ext => "pdf",
    }, 
    pdfbook => {
        out => "bookdown::pdf_document2",
        ext => "pdf",
    }, 
    odt => {
        out => "rmarkdown::odt_document",
        ext => "odt",
    }, 
    docx => {
        out => "officedown::rdocx_document",
        opt => [
            qq/tables = list(caption = list(pre = 'Table:', sep = '  '))/, 
            qq/plots  = list(caption = list(pre = 'Figure:', sep = '  '))/, 
        ],
        ext => "docx",
    },
    docxbook => {
        out => "bookdwon::word_document2",
        ext => "docx",
    },
    pptx => {
        out => "officedown::rpptx_document", 
        opt => [
            qq/base_format = 'rmarkdown::powerpoint_presentation'/, 
            qq/toc = TRUE/,
            qq/toc_depth = 1/,
            qq/slide_level = 2/, 
        ],
    },
    beamer => {
        out => "rmarkdown::beamer_presentation",
        opt => [
            qq/slide_level = 2/,
        ],
        ext => "pdf",
    },
    html => {
        out => "rmarkdown::html_document",
        ext => "html",
    },
    htmlbook => {
        out => "bookdown::html_document2",
        ext => "html",
    },
);

sub rmd2md {
    my ($infile, $to, $md_contents, $pandoc_options, $logfile) = @_;
    $logfile //= "/dev/null";
    # $infile, 待转换的原文件
    # $to，转换的目标格式
    # $md_contest, markdown 文件的内容，列表引用格式
    # $pandoc_options, pandoc 选项，列表引用格式

    my $basename = fileparse($infile, qr/\.[Rr](md|markdown)/);
    my $tdir = tempdir();
    my $outfile = catfile($tdir, $basename . ".knit.md");
    my %out = %{$rmd_render_option{$to}};
    $out{opt} //= [];
    $out{opt} = join ", ", @{$out{opt}};
    my $opt = $out{opt};
    my $cmd = qq{
        rmarkdown::render('$infile',
                          output_format = $out{out}($out{opt}),
                          intermediates_dir = '$tdir',
                          quiet = TRUE,
                          run_pandoc = FALSE)
    };
    system(qq{Rscript --verbose -e "$cmd" >>$logfile 2>>$logfile});
    system("cat $outfile");
    open my $md_fh, "<", $outfile or die "Cannot open file $outfile";
    @{$md_contents} = <$md_fh>;
    close $md_fh;

    my $Rlib = qx/Rscript --no-save --no-restore -e 'cat(.libPaths()[1])'/;
    push @{$pandoc_options}, (
        qq<--lua-filter "$Rlib/bookdown/rmarkdown/lua/custom-environment.lua">,
        qq<--lua-filter "$Rlib/rmarkdown/rmarkdown/lua/pagebreak.lua">,
        qq<--lua-filter "$Rlib/rmarkdown/rmarkdown/lua/latex-div.lua">,
        qq<--variable graphics>);
    return $out{ext};
}

#my @md_contents = ();
#my @pandoc_options = ();
#my $infile = "/tmp/test.Rmd";
#my $to = "html";
#rmd2md($infile, $to, \@md_contents, \@pandoc_options);

#print join "\n", @md_contents[0..5];
#print join "\n", @pandoc_options;


