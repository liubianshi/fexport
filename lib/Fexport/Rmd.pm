package Fexport::Rmd;

use v5.20;
use strict;
use warnings;
use utf8;
use Exporter 'import';

use Path::Tiny;
use YAML          qw(LoadFile);
use IPC::Run3     qw(run3);
use Fexport::Util qw(find_resource require_hash_args);

our @EXPORT_OK = qw(render_rmd);

sub render_rmd {
  my ($args) = @_;

  # 参数契约：与 render_qmd 一致，接收单个 hashref（见 t/render_contract.t）
  require_hash_args( 'render_rmd', $args, qw(infile to) );

  my $infile_raw      = $args->{infile};
  my $to_format       = $args->{to};
  my $pandoc_opts_ref = $args->{pandoc_opts} // [];    # 缺省空数组，避免 push 到非数组引用

  # 1. 准备路径
  my $infile = path($infile_raw)->absolute;
  die "Error: Input file '$infile_raw' not found.\n" unless $infile->exists;

  my $rscript_path = find_resource("parse_rmd.R");
  my $rmd_opt_path = find_resource("rmd_option.yaml");

  die "Error: 'parse_rmd.R' not found.\n"     unless $rscript_path && -e $rscript_path;
  die "Error: 'rmd_option.yaml' not found.\n" unless $rmd_opt_path && -e $rmd_opt_path;

  # 2. 准备接收 R 结果的临时文件
  my $meta_yaml_tmp = Path::Tiny->tempfile( SUFFIX => '.yaml' );

  # 3. 调用 R 脚本
  # 命令格式: Rscript parse_rmd.R <format> <infile> <config> <output_yaml>
  my @cmd = ( 'Rscript', $rscript_path, $to_format, $infile->stringify, $rmd_opt_path, $meta_yaml_tmp->stringify );

  # 安全执行
  if ( system(@cmd) != 0 ) {
    die "RMarkdown rendering failed (Exit code: $?).\n";
  }

  # 4. 读取 R 返回的元数据
  my $meta = LoadFile( $meta_yaml_tmp->stringify );

  # 5. 处理结果
  my @clean_files;
  my @md_lines;

  # A. 添加 LaTeX 依赖
  if ( $meta->{knit_meta} && -f $meta->{knit_meta} ) {
    push @$pandoc_opts_ref, "--include-in-header=" . $meta->{knit_meta};

    # knit_meta 文件通常在 cache 里，是否需要清理视情况而定
  }

  # B. 处理 Lua Filters (从 R 包中动态获取的路径)
  if ( $meta->{lua_filters} && ref $meta->{lua_filters} eq 'ARRAY' ) {
    for my $lua ( @{ $meta->{lua_filters} } ) {
      push @$pandoc_opts_ref, "--lua-filter=$lua";

      # 特殊处理 pagebreak.lua 依赖的 shared.lua
      if ( $lua =~ m{pagebreak\.lua$} ) {
        my $shared = $lua;
        $shared =~ s{pagebreak\.lua}{shared.lua};
        $ENV{RMARKDOWN_LUA_SHARED} = $shared if -e $shared;
      }
    }
  }

  # C. 检查是否需要读取中间 Markdown 内容
  # 如果 R 配置说 run_pandoc = FALSE (或 'no')，说明 Pandoc 步骤由 Perl 接管
  # 这时我们需要读取 R 生成的中间文件 (.knit.md 或 .md)
  my $run_pandoc = $meta->{run_pandoc};

  # 规范化布尔判断：R 的 yaml::write_yaml 把 TRUE 写成 `yes`、FALSE 写成 `no`，
  # 而 YAML.pm 原样读成字符串，故须按 YAML 1.1 的真值拼写全集判断。
  # 只认 'true'/'1' 时 `yes` 会被判为假，Perl 会把 R 已生成的 .docx 当 UTF-8 文本重读。
  my $is_pandoc_run_by_r = ( defined $run_pandoc && $run_pandoc =~ /\A(?:1|y|yes|true|on)\z/i );

  unless ($is_pandoc_run_by_r) {
    my $outfile = path( $meta->{outfile} );

    if ( $outfile->exists ) {
      @md_lines = $outfile->lines_utf8;
      push @clean_files,      $outfile->stringify;
      push @$pandoc_opts_ref, "--variable=graphics";

      say "[Perl] Loaded intermediate content from: $outfile";
    }
    else {
      warn "[Warn] R script finished but output file '$outfile' is missing.\n";
    }
  }

  # 6. 返回结构化结果
  return {
    meta        => $meta,
    md_lines    => \@md_lines,      # 如果有内容，说明需要 Perl 继续跑 Pandoc
    clean_files => \@clean_files,
  };
}

1;
