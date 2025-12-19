package Fexport::Quarto;

use v5.20;
use strict;
use warnings;
use Exporter 'import';

# 核心依赖更新
use Path::Tiny;
use Digest::MD5 qw(md5_hex);
use File::Spec;
use YAML         qw(LoadFile DumpFile Load);
use Scope::Guard qw(guard);
use List::Util   qw(uniq);
use IPC::Run3    qw(run3);                     # 用于捕获 xdotool 输出等
use List::Util   qw(uniq);
use POSIX        qw(setsid);
use IPC::Cmd     qw(can_run);

use Cwd                  qw(getcwd);
use Fexport::Util        qw(save_lines find_resource find_pandoc_datadir launch_browser_preview);
use Fexport::PostProcess qw(fix_citation_etal postprocess_html postprocess_latex postprocess_docx);

our @EXPORT_OK = qw(render_qmd);

# 常量定义
my $PANDOC_DIR = path( find_pandoc_datadir() );

sub render_qmd {
  my (
    $infile_raw, $outformat,          $outfile_final,    $lang, $preview,
    $verbose,    $keep_intermediates, $outfile_abs_path, $browser
    )
    = @_;

  # 1. 路径对象化
  # $outfile_abs_path 是最终目标的绝对路径 (由脚本传入)
  # Quarto 强制在 CWD 生成文件，所以我们需要计算一个临时的本地文件名
  my $infile     = path($infile_raw)->absolute;
  my $final_dest = path($outfile_abs_path);

  # 2. 加载 Quarto 配置
  my $quarto_config_file = find_resource("quarto_option.yaml");
  my $quarto_options     = -e $quarto_config_file ? LoadFile($quarto_config_file) : {};
  my $format_config      = $quarto_options->{$outformat} // {};

  # 确定中间格式 (例如 pdf -> latex) 和扩展名
  my $quarto_target     = $format_config->{intermediate}     // $outformat;
  my $quarto_target_ext = $format_config->{intermediate_ext} // $quarto_target;

  # 3. 计算本地临时文件名 (Local Intermediate)
  # 逻辑：取 final_dest 的文件名，但替换后缀为 quarto 的目标后缀
  my $local_outfile = path( $final_dest->basename );
  if ( $quarto_target_ext ne $outformat ) {
    my $base = $local_outfile->basename(qr/\.[^.]+$/);
    $local_outfile = path( $base . "." . $quarto_target_ext );
  }

  # 4. 元数据 (Metadata) 注入与保护
  # 使用 _metadata.yml (目录级别元数据) 而非 _quarto.yml (项目级别配置)
  # 这样不会干扰用户的项目配置
  {
    my $meta_file      = $infile->parent->child("_metadata.yml");
    my $backup_file    = $meta_file->parent->child( $meta_file->basename . "_bck" );
    my $generated_meta = 0;

    my $guard = guard {
      $meta_file->remove             if $generated_meta;
      $backup_file->move($meta_file) if $backup_file->exists;
    };

    if ( $meta_file->exists ) {
      $meta_file->move($backup_file);
    }

    my $defaults_path = $PANDOC_DIR->child( "defaults", "2${quarto_target}.yaml" );
    my $default_meta  = _load_pandoc_defaults($defaults_path);
    my $meta_data     = {};

    if ( $backup_file->exists ) {
      # 如果存在项目的 _quarto.yml (即备份文件)，以此为基础
      $meta_data = LoadFile($backup_file);
      # 将默认配置填入项目配置（仅当项目配置缺少该项时）
      _merge_yaml( $meta_data, $default_meta );
    }
    else {
      # 否则完全使用默认配置
      $meta_data = $default_meta;
    }

    # 修正 Template 路径 (相对 -> 绝对)
    if ( exists $meta_data->{template} && !path( $meta_data->{template} )->is_absolute ) {
      my $tmpl_name = $meta_data->{template};
      $tmpl_name .= ".${quarto_target}" if $tmpl_name !~ /\.\w+$/;

      # 2. 定义探测路径候选列表
      my $local_tmpl  = path($tmpl_name);                                 # 候选A: 当前工作目录 (CWD)
      my $pandoc_tmpl = $PANDOC_DIR->child( "templates", $tmpl_name );    # 候选B: ~/.pandoc/templates/

      # 3. 探测逻辑
      if ( $local_tmpl->exists ) {
        $meta_data->{template} = $local_tmpl->absolute->stringify;
      }
      elsif ( $pandoc_tmpl->exists ) {
        $meta_data->{template} = $pandoc_tmpl->absolute->stringify;
      }
      elsif ( $meta_data->{template} !~ /^\s*default\s*$/ ) {
        die "Error: Template file '$tmpl_name' not found.\n"
          . "Searched in:\n"
          . "  1. Current Directory: "
          . path('.')->absolute . "\n"
          . "  2. Pandoc Directory:  "
          . $PANDOC_DIR->child("templates") . "\n";
      }
    }

    # 覆盖语言设置
    $lang //= $meta_data->{lang};
    $meta_data->{lang} = $lang;

    DumpFile( $meta_file->stringify, $meta_data );
    $generated_meta = 1;

    # 5. 执行 Quarto Render
    my @quarto_cmd = (
      "quarto",           "render",
      $infile->stringify, "--to=$quarto_target",
      "--execute-dir",    getcwd(),
      "--output",         $local_outfile,
      "--lua-filter",     $PANDOC_DIR->child("filters/quarto_docx_embeded_table.lua")->stringify,
      "--lua-filter",     $PANDOC_DIR->child("filters/rsbc.lua")->stringify
    );

    # Explicitly pass pdf-engine if set (prevents Quarto from ignoring it)
    if ( my $pdf_engine = $meta_data->{'pdf-engine'} ) {
      push @quarto_cmd, "--pdf-engine=$pdf_engine";
    }

    print join( " ", @quarto_cmd ), "\n";

    # 使用列表 system，安全
    system(@quarto_cmd) == 0 or die "Failed to run quarto: $?";

    # Guard 会在离开此块时自动执行清理恢复
  }

  # 6. 后处理与移动 (Post-process & Move)
  if ( $outformat eq "html" ) {
    _process_html_output( $local_outfile, $preview, $final_dest, $browser );

    # HTML 处理完后，如果 local_outfile 和 final_dest 不一样，清理 local
    $local_outfile->remove if $local_outfile->absolute ne $final_dest->absolute;
  }
  elsif ( $outformat eq "pdf" ) {
    _process_pdf_output( $local_outfile, $verbose, $keep_intermediates, $final_dest, $infile );

    # PDF 处理函数内部会移动文件，这里只需清理 tex
    $local_outfile->remove if $local_outfile->exists && !$keep_intermediates;
  }
  elsif ( $outformat eq "docx" ) {

    # 原代码 bug 修复：先处理，再移动
    _process_docx_output( $local_outfile, $lang );
    $local_outfile->move($final_dest);
  }
  else {
    # 默认情况：直接移动
    $local_outfile->move($final_dest) if $local_outfile->absolute ne $final_dest->absolute;
  }
}

# --- Helpers ---

sub _process_html_output {
  my ( $infile, $preview, $outfile_dest, $browser ) = @_;

  # 模拟原来的数组引用接口
  my @lines = $infile->lines_utf8();

  fix_citation_etal( \@lines );
  postprocess_html( \@lines );

  # 写入最终位置
  path($outfile_dest)->spew_utf8(@lines);

  launch_browser_preview( $outfile_dest, $browser ) if $preview;
}

sub _process_pdf_output {
  my ( $tex_file, $verbose, $keep, $final_pdf_dest, $infile ) = @_;

  # Quarto Book projects output to _book/ subdirectory, try fallback
  if ( !$tex_file->exists ) {
    # First try _book/ in CWD (where Quarto renders)
    my $book_tex = path("_book")->child($tex_file->basename);
    if ( $book_tex->exists ) {
      $tex_file = $book_tex;
    }
    # Also try _book/ in infile's parent directory
    elsif ( defined $infile ) {
      $book_tex = $infile->parent->child("_book")->child($tex_file->basename);
      if ( $book_tex->exists ) {
        $tex_file = $book_tex;
      }
    }
  }

  die "Error: TeX file '$tex_file' not found." unless $tex_file->exists;

  # 读入 TeX 内容
  my @lines = $tex_file->lines_utf8;
  postprocess_latex( \@lines );

  # 临时编译目录
  my $temp_dir = Path::Tiny->tempdir( CLEANUP => !$keep );
  if ($keep) {
    say "Intermediate files kept in: $temp_dir";
  }

  my $temp_tex = $temp_dir->child("intermediate.tex");
  $temp_tex->spew_utf8(@lines);

  # 构建 latexmk 命令 (列表形式)
  my @cmd =
    ( 'latexmk', '-xelatex', "-outdir=" . $temp_dir->stringify, $verbose ? () : '-quiet', $temp_tex->stringify );

  system(@cmd) == 0 or die "Failed to render LaTeX file: $?";

  # 移动结果
  my $generated_pdf = $temp_dir->child("intermediate.pdf");
  if ( $generated_pdf->exists ) {
    $generated_pdf->move($final_pdf_dest);
    say "PDF generated: $final_pdf_dest";
  }
  else {
    die "Error: latexmk finished but PDF not found.";
  }
}

sub _process_docx_output {
  my ( $docx_file, $lang ) = @_;
  if ( $lang eq 'zh' ) {

    # 这里的 postprocess_docx 应该是原地修改 docx (解压-修改-打包)
    postprocess_docx( $docx_file->stringify );
  }
}

# --- Config & Metadata Helpers ---

sub _load_pandoc_defaults {
  my $file = shift;
  return {} unless defined $file && $file->exists;

  my $yaml = LoadFile($file);
  _substitute_env($yaml);
  return $yaml;
}

sub _substitute_env {
  my ($data) = @_;
  return unless defined $data;

  my $ref = ref $data;
  if ( !$ref ) {

    # 原地修改 Scalar (利用 $_[0] 的别名特性)
    # 替换 $VAR 或 ${VAR}，默认为空
    $_[0] =~ s/\$[{]?(\w+)[}]?/$ENV{$1} \/\/ ''/eg;
  }
  elsif ( $ref eq 'HASH' ) {
    _substitute_env($_) for values %$data;
  }
  elsif ( $ref eq 'ARRAY' ) {
    _substitute_env($_) for @$data;
  }
  elsif ( $ref eq 'SCALAR' ) {
    _substitute_env($$data);
  }
}

sub _merge_yaml {
  my ( $dest, $src ) = @_;

  while ( my ( $key, $val_src ) = each %$src ) {
    if ( !exists $dest->{$key} ) {
      $dest->{$key} = $val_src;
      next;
    }

    my $r_dest = ref $dest->{$key} || '';
    my $r_src  = ref $val_src      || '';

    if ( $r_dest eq 'HASH' && $r_src eq 'HASH' ) {
      _merge_yaml( $dest->{$key}, $val_src );
    }
    elsif ( $r_dest eq 'ARRAY' && $r_src eq 'ARRAY' ) {
      $dest->{$key} = [ uniq( @{ $dest->{$key} }, @$val_src ) ];
    }
    else {
      # 其他情况（标量或类型不匹配），直接覆盖
      $dest->{$key} = $val_src;
    }
  }
}

sub _find_or_default_quarto_yaml {
    my $infile = shift;
    
    # Just check CWD for _quarto.yml
    my $cwd_config = path("_quarto.yml");
    return $cwd_config if $cwd_config->exists;
    
    # Default to infile directory if not found
    return $infile->parent->child("_quarto.yml");
}

1;
