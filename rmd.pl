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
        render            => "bookdown::render_book",
        out               => "bookdown::pdf_document2",
        outfile           => "draft.knit.md",
        intermediates_dir => "_cache",
        ext               => "pdf",
        opt               => [ q/number_section = FALSE/,
                               q/keep_md        = TRUE/,
                               q/tables         = list(caption = list(pre = '表', sep = '  '))/,
                               q/plots          = list(caption = list(pre = '图', sep = '  '))/,
                           ],
    },
    rdocxbook => { 
        out               => "officedown::rdocx_document",
        render            => "bookdown::render_book",
        outfile           => "draft.docx",
        intermediates_dir => "_cache",
        output_dir        => ".",
        run_pandoc        => "TRUE",
        opt               => [ q/base_format    = 'bookdown::word_document2'/,
                               q/number_section = FALSE/,
                               q/pandoc_args    = c('-d2docx', '--lua-filter=rsbc.lua')/,
                               q/keep_md        = TRUE/,
                               q/tables         = list(caption = list(pre = '表', sep = '  '))/,
                               q/plots          = list(caption = list(pre = '图', sep = '  '))/,
                           ],
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
        intermediates_dir => "_cache",
        output_dir        => ".",
        outfile           => "draft.docx",
        run_pandoc        => "TRUE",
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

my %rmd_default = (
    render => "rmarkdown::render",
    run_pandoc => "FALSE",
    intermediates_dir => tempdir(),
    opt => [],
);


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
    my $render     = $rmd{render}            // "rmarkdown::render";
    my $tdir       = $rmd{intermediates_dir} // tempdir();
    my $odir       = $rmd{output_dir}        // $tdir;
    $rmd{outfile}  = catfile($odir, $rmd{outfile} // $basename . ".knit.md");

    my $tempdir = tempdir();
    my $perl_cmd_in_R = q|perl -MFile::Copy -pli -E \\'|
           . "\n\t\t" .  q|my \$rdocx_embed_graph = q<r:embed=\"(/tmp/Rtmp[A-z0-9]+)/(file[A-z0-9]+.[A-z0-9]+)\">;|
           . "\n\t\t" . qq|my \\\$tdir = q<$tempdir>;|
           . "\n\t\t" .  q|if (m{\$rdocx_embed_graph}) {
                        copy(qq<\$1/\$2>, \$tdir) ;
                        s{\$rdocx_embed_graph}{r:embed=\"\$tdir/\$2\"};
                    }|
            . "\n\t\t" . qq|\\' \\"$rmd{outfile}\\"|
            ;

    my $R_CMD = "Rscript --no-init-file --no-save --no-restore --verbose";
    my $cmd   = qq{
        options(box.path = file.path(Sys.getenv('HOME'), 'Repositories', 'R-script', 'box'))
        diy_output_format <- $rmd{out}($rmd{opt})
        diy_output_format[['clean_supporting']] <- FALSE
        res <- $render(
            '$infile',
            output_format     = diy_output_format,
            run_pandoc        = $rmd{run_pandoc},
            output_dir        = '$odir',
            intermediates_dir = '$tdir'
        )

        knit_meta <- attr(res, 'knit_meta')
        if (!is.null(knit_meta)) {
            knit_meta <- purrr::map(knit_meta, ~ {
                if (class(.x) == 'latex_dependency') {
                    c(gettextf('\\\\\\usepackage{%s}', .x[['name']]), .x[['extra_lines']])
                } else { NULL }
            }) |> unlist()
            fileConn<-file('_bookdown_files/$tdir/knit_meta')
            writeLines(knit_meta, fileConn)
            close(fileConn)
        }
    };
    system(qq{$R_CMD -e "$cmd"}) == 0 or die "Rmd Parse error!";
    if (-f "_bookdown_files/$tdir/knit_meta") {
        push @{$pandoc_options}, "--include-in-header=" . "_bookdown_files/$tdir/knit_meta" 
    }

    if ($rmd{run_pandoc} eq "FALSE") {
        if (-d "_bookdown_files") {
            $rmd{outfile} = catfile("_bookdown_files", $rmd{outfile});
        }

        open my $md_fh, "<", "$rmd{outfile}"
            or die "Cannot open rmarkdown output $rmd{outfile}: $!";
        @{$md_contents} = <$md_fh>;
        close $md_fh;
        unlink $rmd{outfile};
        push @{$pandoc_options}, map {'--lua-filter="' . $_ . '"'} pandoc_lua_filter_from_r;
        push @{$pandoc_options}, "--variable=graphics";
    }
    return %rmd;
}

1
