package Fexport::Converter;

use v5.20;
use strict;
use warnings;
use Exporter 'import';
use Path::Tiny;
use List::Util qw(first);

use Fexport::Util qw(run_pandoc_and_load run_pandoc save_lines get_pandoc_defaults_flag launch_browser_preview run3);
use Fexport::PostProcess
  qw(fix_citation_etal postprocess_html sanitize_markdown_math postprocess_latex postprocess_docx);

our @EXPORT_OK = qw(convert);

sub convert {
  my ($args) = @_;

  # 建立分发映射表 (Dispatch Table) 或简单的 if-elsif
  # 这里保持 if-elsif 结构简单明了，但逻辑已解耦
  my $format = $args->{format};

  if    ( $format eq "html" ) { return _to_html($args); }
  elsif ( $format eq "docx" ) { return _to_docx($args); }
  elsif ( $format eq "pdf" )  { return _to_pdf($args); }
  else                        { return _to_default($args); }
}

sub _to_html {
  my ($args)      = @_;
  my $pandoc      = $args->{pandoc};
  my $outfile     = path( $args->{outfile} );    # 确保是对象
  my $md_contents = $args->{md_contents};
  my $log_fh      = $args->{log_fh};

  # 使用列表形式添加参数，避免手动加引号转义 "--output=\"$outfile\"" 这种易错写法
  push @$pandoc, get_pandoc_defaults_flag("html"), "--to=html", "--output", $outfile->stringify;

  my @html_contents = run_pandoc_and_load( $md_contents, $pandoc, $outfile->stringify, $log_fh );

  fix_citation_etal( \@html_contents );
  postprocess_html( \@html_contents );
  save_lines( \@html_contents, $outfile );

  # Unified preview logic: use browser-sync for HTML
  launch_browser_preview($outfile, $args->{browser}) if $args->{preview};
}

sub _to_docx {
  my ($args)      = @_;
  my $pandoc      = $args->{pandoc};
  my $outfile     = path( $args->{outfile} );
  my $md_contents = $args->{md_contents};
  my $log_fh      = $args->{log_fh};

  unless ( $args->{pandoc_run} ) {
    push @$pandoc, get_pandoc_defaults_flag("docx"), "--to=docx", "--output", $outfile->stringify;
    run_pandoc( $md_contents, $pandoc, $log_fh );
  }
  postprocess_docx($outfile);
}

sub _to_pdf {
  my ($args)      = @_;
  my $pandoc      = $args->{pandoc};
  my $outfile     = path( $args->{outfile} )->absolute;    # 确保绝对路径，因为 latexmk 会切换目录
  my $md_contents = $args->{md_contents};
  my $log_fh      = $args->{log_fh};
  my $verbose     = $args->{verbose};
  my $keep        = $args->{keep};

  # 1. 准备临时环境
  my $temp_dir = Path::Tiny->tempdir( CLEANUP => !$keep );
  if ($keep) {
    say "Intermediate files kept in: $temp_dir";
  }

  # 2. 生成中间 TeX 文件路径
  my $tex_file = $temp_dir->child("intermediate.tex");

  # 3. 配置 Pandoc 生成 TeX
  push @$pandoc, get_pandoc_defaults_flag("tex"), "--to=latex", "--output", $tex_file->stringify;

  sanitize_markdown_math($md_contents);

  my @tex_contents = run_pandoc_and_load( $md_contents, $pandoc, $tex_file->stringify, $log_fh );

  postprocess_latex( \@tex_contents );
  save_lines( \@tex_contents, $tex_file );

  # 4. 运行 latexmk
  # 使用 run3 替代 system，便于测试 mock 和捕获输出
  my @latexmk_cmd =
    ( 'latexmk', '-xelatex', '-outdir=' . $temp_dir->stringify, $verbose ? () : '-quiet', $tex_file->stringify );

  my $out;
  my $err;
  eval {
      run3 \@latexmk_cmd, \undef, \$out, \$err;
  };
  if ($@) {
      warn "Run3 failed: $@";
  }
  my $ret = $?; # run3 updates $?
  if ( $ret == 0 ) {

    # 5. 移动生成的 PDF 到最终位置
    # latexmk 生成的文件名通常与输入 tex 同名，但后缀为 pdf
    my $generated_pdf = $temp_dir->child("intermediate.pdf");
    if ( $generated_pdf->exists ) {
      $generated_pdf->move($outfile);
    }
    else {
      warn "Error: latexmk finished but '$generated_pdf' not found.\n";
    }
  }
  else {
    warn "Error: latexmk execution failed.\n";
  }
}

sub _to_default {
  my ($args)      = @_;
  my $pandoc      = $args->{pandoc};
  my $outfile     = path( $args->{outfile} );
  my $md_contents = $args->{md_contents};
  my $log_fh      = $args->{log_fh};
  my $format      = $args->{format};

  push @$pandoc, get_pandoc_defaults_flag($format), "--to=$format", "--output", $outfile->stringify;
  run_pandoc( $md_contents, $pandoc, $log_fh );
}

# --- Internal Helpers ---

sub _preview_file {
  my ($file) = @_;
  my $cmd;

  if    ( $^O eq 'darwin' )  { $cmd = 'open' }
  elsif ( $^O eq 'MSWin32' ) { $cmd = 'start' }
  elsif ( $^O eq 'linux' )   { $cmd = 'xdg-open' }

  if ($cmd) {

    # system 列表形式：程序名, 参数...
    # 这样即使文件名有空格也不需要加引号
    system( $cmd, $file->stringify );
  }
}

1;
