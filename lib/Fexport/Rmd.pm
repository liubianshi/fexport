package Fexport::Rmd;
use strict;
use warnings;
use v5.20;
use Exporter 'import';
use YAML qw(LoadFile);
use File::Spec;
use File::Temp qw(tempfile tempdir);
use File::Basename qw(fileparse);
use FindBin qw($RealBin);
use Fexport::Util qw(get_resource_path);

our @EXPORT_OK = qw(knit_rmd2);

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
    opt               => [
      q/number_section = FALSE/,
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
    opt               => [
      q/base_format    = 'bookdown::word_document2'/,
      q/number_section = FALSE/,
      q/pandoc_args    = c('-d2docx', '--lua-filter=rsbc.lua')/,
      q/keep_md        = TRUE/,
      q/tables         = list(caption = list(pre = '表', sep = '  '))/,
      q/plots          = list(caption = list(pre = '图', sep = '  '))/,
    ],
    ext => "docx",
  },
  mdbook => {
    out               => "bookdown::markdown_document2",
    render            => "bookdown::render_book",
    intermediates_dir => ".",
    opt => [ q/base_format    = 'bookdown::word_document2'/, q/number_section = FALSE/, q/keep_md        = TRUE/ ],
    ext => "docx",
  },
  docxbook => {
    out               => "bookdown::word_document2",
    render            => "bookdown::render_book",
    intermediates_dir => "_cache",
    output_dir        => ".",
    outfile           => "draft.docx",
    run_pandoc        => "TRUE",
    opt               =>
      [ q/pandoc_args    = c('-d2docx', '--lua-filter=rsbc.lua')/, q/number_section = FALSE/, q/keep_md  = TRUE/, ],
    ext => "docx",
  },
  odt  => { out => "rmarkdown::odt_document", ext => "odt" },
  docx => {
    out               => "officedown::rdocx_document",
    intermediates_dir => ".",
    opt               => [
      qq/tables = list(caption = list(pre = 'Table:', sep = '  '))/,
      qq/plots  = list(caption = list(pre = 'Figure:', sep = '  '))/,
    ],
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
    to         => "pptx",
    ext        => "pptx"
  },
  beamer => {
    out => "rmarkdown::beamer_presentation",
    opt => [ qq/slide_level = 2/, ],
    to  => "beamer",
    ext => "pdf",
  },
  html     => { out => "rmarkdown::html_document", ext => "html", opt => [] },
  htmlbook => { out => "bookdown::html_document2", ext => "html", opt => [] },
);

sub knit_rmd2 {
  my ( $infile, $to, $md_contents_ref, $pandoc_opt_ref, $logfile ) = @_;

  # $infile, 待转换的原文件
  # $to，转换的目标格式
  # $md_contest, markdown 文件的内容，列表引用格式
  # $pandoc_options, pandoc 选项，列表引用格式
  
  # Forward variable declaration to handle clean up (files_needed_clean is likely global in script, need adapt)
  # For now, we will return the file to clean
  my @files_needed_clean = ();

  my $rscript_path = get_resource_path( "parse_rmd.R" );
  my $rmd_opt_path = get_resource_path( "rmd_option.yaml" );
  my ( $result_fh, $result ) = tempfile();
  close $result_fh;

  if ( system(qq{$rscript_path $to "$infile" "$rmd_opt_path" "$result"}) != 0 ) {
    unlink $result;
    die "Failed to parse $infile: $?";
  }
  my %rmd = %{ LoadFile($result) };
  unlink $result;
  # use Data::Dump qw(dump);
  # dump %rmd;

  if ( defined $rmd{knit_meta} and -f $rmd{knit_meta} ) {
    push @{$pandoc_opt_ref}, "--include-in-header=" . $rmd{knit_meta};
  }

  say $rmd{outfile};
  if ( $rmd{run_pandoc} eq 'no' ) {
    open my $md_fh, "<", $rmd{outfile}
      or die "Cannot open rmarkdown output: $!";
    @{$md_contents_ref} = <$md_fh>;
    close $md_fh;
    for ( @{ $rmd{lua_filters} } ) {
      push @{$pandoc_opt_ref}, qq(--lua-filter="$_");
      if ( $_ =~ m{rmarkdown/rmarkdown/lua/pagebreak.lua$} ) {
        $ENV{RMARKDOWN_LUA_SHARED} = s{pagebreak\.lua}{shared.lua}r;
      }
    }

    push @files_needed_clean, $rmd{outfile};
    push @{$pandoc_opt_ref},  "--variable=graphics";
  }
  
  $rmd{files_needed_clean} = \@files_needed_clean;
  return %rmd;
}

1;
