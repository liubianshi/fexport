package Fexport::Defaults;

use v5.20;
use strict;
use warnings;
use Exporter 'import';
use JSON::PP;
use Fexport::Util qw(find_resource);

our @EXPORT_OK = qw(get_defaults);

sub get_defaults {

  # Dynamically find the share directory
  my $share_dir = find_resource('header.tex');
  if ($share_dir) {
    $share_dir =~ s{/header\.tex$}{};
  }
  else {
    $share_dir = $ENV{FEXPORT_SHARE} // '/usr/local/share/fexport';
  }

  my $true  = JSON::PP::true;
  my $false = JSON::PP::false;

  # Markdown extensions
  my $md_extensions = [
    qw(
      emoji
      east_asian_line_breaks
      autolink_bare_uris
      mark
      lists_without_preceding_blankline
      wikilinks_title_before_pipe
      )
  ];

  my $md_tex_extensions = [ @$md_extensions, 'raw_tex' ];

  # Fonts
  my $cjk_fonts = {
    CJKmainfont => "方正聚珍新仿简体",
    CJKsansfont => "Source Han Sans CN",
    CJKmonofont => "LXGW WenKai Mono",
  };

  my $western_fonts = {
    mainfont => "Times New Roman",
    sansfont => "Source Han Sans CN",
    monofont => "FiraCode Nerd Font Mono",
    mathfont => "DejaVu Math TeX Gyre",
  };

  # Bibliography
  my $biblatex_opts = {
    "biblio-style"    => "gb7714-2015ay",
    "biblio-title"    => "参考文献",
    "biblatexoptions" => "backend=biber,gbnamefmt=familyahead",
  };

  # Metadata
  my $chinese_meta = {
    author                    => ["罗伟"],
    "reference-section-title" => "参考文献",
    "link-citations"          => $true,
  };

  # Variables
  my $tex_vars = { %$cjk_fonts, %$western_fonts, %$biblatex_opts, indent => $true, };

  my $beamer_vars = { %$cjk_fonts, %$western_fonts, %$biblatex_opts, };

  my $formats = {
    beamer => {
      ext                   => "pdf",
      intermediate          => "latex",
      intermediate_ext      => "tex",
      from                  => 'markdown+' . join( '+', @$md_extensions ),
      "syntax-highlighting" => "pygments",
      "pdf-engine"          => "xelatex",
      "slide-level"         => 2,
      citeproc              => $true,
      template              => "$share_dir/templates/beamer-diy",
      "include-in-header"   => [ "$share_dir/header.tex", "$share_dir/beamerheader.tex", ],
      variables             => {
        %$beamer_vars,
        fonttheme        => "structurebold",
        institute        => "南开大学 APEC 研究中心",
        "section-titles" => $false,
        toc              => $false,
        "toc-title"      => "主要内容",
        "toc-depth"      => 1,
      },
    },
    docx => {
      ext                   => "docx",
      from                  => 'markdown+' . join( '+', @$md_extensions ),
      "syntax-highlighting" => "pygments",
      "reference-doc"       => "$share_dir/templates/economic-research-china.docx",
      csl                   => "$share_dir/china-national-standard-gb-t-7714-2015-author-date.csl",
      metadata              => {
        "link-citations" => $false,
      },
    },
    html => {
      ext                   => "html",
      from                  => 'markdown+' . join( '+', @$md_extensions ),
      to                    => "html",
      template              => "normal",
      "syntax-highlighting" => "pygments",
      "html-math-method"    => { method => "katex" },
      "embed-resources"     => $false,
      metadata              => {
        "reference-section-title" => "参考文献",
        "link-citations"          => $true,
      },
    },
    pdf => {
      ext                   => "pdf",
      intermediate          => "latex",
      intermediate_ext      => "tex",
      metadata              => {%$chinese_meta},
      from                  => 'markdown+' . join( '+', @$md_extensions ),
      "syntax-highlighting" => "pygments",
      template              => "$share_dir/templates/eisvogel.latex",
      listings              => $true,
      "pdf-engine"          => "xelatex",
      citeproc              => $true,
      "include-in-header"   => ["$share_dir/header.tex"],
      variables             => {%$tex_vars},
    },
    pptx => {
      ext                   => "pptx",
      from                  => 'markdown+' . join( '+', @$md_extensions ),
      to                    => "pptx",
      citeproc              => $true,
      "syntax-highlighting" => "pygments",
      "reference-doc"       => "$share_dir/templates/custom-reference.pptx",
      csl                   => "$share_dir/china-national-standard-gb-t-7714-2015-author-date.csl",
      metadata              => {
        "reference-section-title" => "参考文献",
        "link-citations"          => $true,
      },
    },
    tex => {
      ext                   => "tex",
      metadata              => {%$chinese_meta},
      from                  => 'markdown+' . join( '+', @$md_tex_extensions ),
      "syntax-highlighting" => "pygments",
      template              => "$share_dir/templates/eisvogel.latex",
      listings              => $true,
      "pdf-engine"          => "xelatex",
      variables             => {%$tex_vars},
    },
    latex => {
      ext                   => "tex",
      metadata              => {%$chinese_meta},
      from                  => 'markdown+' . join( '+', @$md_tex_extensions ),
      "syntax-highlighting" => "pygments",
      template              => "$share_dir/templates/eisvogel.latex",
      listings              => $true,
      "pdf-engine"          => "xelatex",
      variables             => {%$tex_vars},
    },
  };

  # Assembling the comprehensive defaults
  return {
    # Global application defaults
    global => {
      verbose => 0,
      keep    => 0,
      preview => 0,
      lang    => "zh",
      pandoc  => {
        cmd             => "pandoc +RTS -M512M -RTS",
        "markdown-exts" => [qw(md markdown rmd rmarkdown qmd quarto)],
        filters         => [
          "--filter=pandoc-crossref", "--lua-filter=$share_dir/filters/rm-test-table-line.lua",
          "--citeproc",               "--lua-filter=$share_dir/filters/rsbc.lua",
        ],
        "user-opts"    => [],
        "markdown-fmt" => join( '+', 'markdown', @$md_extensions ),
      },
    },

    # Format-specific configurations
    formats => $formats,
  };
}

1;
