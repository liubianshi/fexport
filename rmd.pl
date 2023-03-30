#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Encode;
use File::Basename;
use File::Temp qw/tempfile tempdir/;
use File::Spec::Functions qw/catfile file_name_is_absolute rel2abs/;

my %rmd_render_option = (
    pdf => {
        out => "rmarkdown::pdf_document",
        ext => "pdf"
    },
    pdfbook => {
        out => "bookdown::pdf_document2",
        ext => "pdf",
    },
    rdocxbook => { 
        out               => "officedown::rdocx_document",
        render            => "bookdown::render_book",
        outfile           => "draft.docx",
        intermediates_dir => ".",
        output_dir        => "_book",
        run_pandoc        => "TRUE",
        opt               => [ q/base_format    = 'bookdown::word_document2'/,
                               q/number_section = FALSE/,
                               q/pandoc_args    = c('-d2docx', '--lua-filter=rsbc.lua')/,
                               q/keep_md        = TRUE/,
                               q/tables         = list(caption = list(pre = '表', sep = '  '))/,
                               q/plots          = list(caption = list(pre = '图', sep = '  '))/, ],
        ext               => "docx",
    },
    mdbook => { 
        out               => "bookdown::markdown_document2",
        render            => "bookdown::render_book",
        intermediates_dir => ".",
        opt               => [ q/base_format    = 'bookdown::word_document2'/,
                               q/number_section = FALSE/,
                               q/keep_md        = TRUE/],
        ext               => "docx",
    },
    docxbook => {
        out               => "bookdown::word_document2",
        render            => "bookdown::render_book",
        intermediates_dir => ".",
        outfile           => "_book/draft.docx",
        run_pandoc        => "TRUE",
        output_dir        => "_book",
        opt               => [ q/pandoc_args    = c('-d2docx', '--lua-filter=rsbc.lua')/,
                               q/number_section = FALSE/,
                               q/keep_md  = TRUE/,        ],
        ext               => "docx",
    },
    odt      => { out => "rmarkdown::odt_document", ext => "odt"},
    docx     => { out => "officedown::rdocx_document",
                  intermediates_dir => ".",
                  opt => [ qq/tables = list(caption = list(pre = 'Table:', sep = '  '))/, 
                           qq/plots  = list(caption = list(pre = 'Figure:', sep = '  '))/, ],
                  ext => "docx", },
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
    push @filter, "rsbc.lua";
    return @filter;
}

sub knit_rmd {
    my ($infile, $to, $md_contents, $pandoc_options, $logfile) = @_;
    # $infile, 待转换的原文件
    # $to，转换的目标格式
    # $md_contest, markdown 文件的内容，列表引用格式
    # $pandoc_options, pandoc 选项，列表引用格式

    my %rmd        = %{$rmd_render_option{$to}};
    my $basename   = fileparse($infile, qr/\.[Rr](md|markdown)/);
    $rmd{opt}      = defined($rmd{opt}) ? join(", ", @{$rmd{opt}}) : "";
    $rmd{run_pandoc} //= "FALSE";
    my $run_pandoc = $rmd{run_pandoc} // "FALSE";
    my $render     = $rmd{render}            // "rmarkdown::render";
    my $tdir       = $rmd{intermediates_dir} // tempdir();
    my $odir       = $rmd{output_dir}        // $tdir;
    $rmd{outfile}  = catfile($tdir, $rmd{outfile} // $basename . ".knit.md");

    my $tempdir = tempdir();
    my $perl_cmd_in_R = q|perl -MFile::Copy -pli -E \\'|
           . "\n" .  q|my \$rdocx_embed_graph = q<r:embed=\"(/tmp/Rtmp[A-z0-9]+)/(file[A-z0-9]+.[A-z0-9]+)\">;|
           . "\n" . qq|my \\\$tdir = q<$tempdir>;|
           . "\n" .  q|if (m{\$rdocx_embed_graph}) {
                        copy(qq<\$1/\$2>, \$tdir) ;
                        s{\$rdocx_embed_graph}{r:embed=\"\$tdir/\$2\"};
                        }|
            . "\n" . qq|\\' \\"$rmd{outfile}\\"|
            ;

    my $R_CMD = "Rscript --no-init-file --no-save --no-restore --verbose";
    my $cmd   = qq{
        options(box.path = file.path(Sys.getenv('HOME'), 'Repositories', 'R-script', 'box'))
        diy_output_format <- $rmd{out}($rmd{opt})
        diy_output_format[['clean_supporting']] <- FALSE
        $render(
            '$infile',
            output_format     = diy_output_format,
            run_pandoc        = $rmd{run_pandoc},
            output_dir        = '$odir',
            intermediates_dir = '$tdir'
        )
        if (!$rmd{run_pandoc}) {
            system(\'$perl_cmd_in_R\n\')
        }
    };
    system(qq{$R_CMD -e "$cmd"});

    if ($rmd{run_pandoc} eq "FALSE") {
        open my $md_fh, "<", "$rmd{outfile}"
            or die "Cannot open rmarkdown output $rmd{outfile}: $!";
        @{$md_contents} = <$md_fh>;
        close $md_fh;
        unlink $rmd{outfile};
        rmdir $tdir;

        push @{$pandoc_options}, map {'--lua-filter="' . $_ . '"'} pandoc_lua_filter_from_r;
        push @{$pandoc_options}, "--variable=graphics";
    }
    return %rmd;
}

1
