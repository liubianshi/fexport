package Fexport::Quarto;

use v5.20;
use strict;
use warnings;
use utf8;
use Exporter 'import';

# 核心依赖
use Path::Tiny;
use Digest::MD5 qw(md5_hex);
use File::Spec;
use YAML                 qw(LoadFile DumpFile Load);
use Scope::Guard         qw(guard);
use List::Util           qw(uniq);
use IPC::Run3            qw(run3);
use POSIX                qw(setsid);
use IPC::Cmd             qw(can_run);
use Cwd                  qw(getcwd);
use Cwd                  qw(getcwd);
use Fexport::Util        qw(save_lines find_resource find_pandoc_datadir launch_browser_preview);
use Fexport::PostProcess qw(fix_citation_etal postprocess_html postprocess_latex postprocess_docx);
use Term::ANSIColor      qw(:constants);
use IPC::Run3            qw(run3);
use Encode               qw(encode_utf8);

$Term::ANSIColor::AUTORESET = 1;

our @EXPORT_OK = qw(render_qmd);

# 常量定义
my $PANDOC_DIR = path( find_pandoc_datadir() );

# ============================================================================
# 主入口函数
# ============================================================================

sub render_qmd {
  my ($args) = @_;

  # 解构参数
  my $infile_raw = $args->{infile};
  my $outformat  = $args->{to};
  my $outfile    = $args->{outfile};
  my $lang       = $args->{lang};
  my $preview    = $args->{preview};
  my $verbose    = $args->{verbose};
  my $keep       = $args->{keep};
  my $browser    = $args->{browser};

  # 1. 路径对象化
  my $infile     = path($infile_raw)->absolute;
  my $final_dest = path($outfile);

  # 2. 加载格式配置
  my $format_config = _load_format_config($outformat);

  # 3. 确定 Quarto 目标格式
  my $quarto_target     = $format_config->{intermediate}     // $outformat;
  my $quarto_target_ext = $format_config->{intermediate_ext} // $quarto_target;

  # 4. 计算本地临时输出文件名
  my $local_outfile = _calculate_local_outfile( $infile, $final_dest, $quarto_target_ext, $outformat );

  # 5. 执行 Quarto 渲染 (带元数据保护)
  $lang = _run_quarto_with_metadata(
    infile        => $infile,
    format_config => $format_config,
    quarto_target => $quarto_target,
    local_outfile => $local_outfile,
    lang          => $lang,
    verbose       => $verbose,
  );

  # 6. 后处理与移动
  _dispatch_postprocess(
    outformat     => $outformat,
    local_outfile => $local_outfile,
    final_dest    => $final_dest,
    infile        => $infile,
    lang          => $lang,
    preview       => $preview,
    verbose       => $verbose,
    keep          => $keep,
    browser       => $browser,
  );
}

# ============================================================================
# 配置加载
# ============================================================================

sub _load_format_config {
  my ($outformat) = @_;

  my $config_file   = find_resource("defaults.yaml");
  my $all_options   = -e $config_file ? LoadFile($config_file) : {};
  my $format_config = $all_options->{$outformat} // {};

  # 设置 FEXPORT_SHARE 环境变量，指向 share 目录
  my $share_dir = path($config_file)->parent->stringify;
  local $ENV{FEXPORT_SHARE} = $share_dir;

  # 展开环境变量
  _substitute_env($format_config);

  # 处理 from-extensions: 将扩展列表转换为 from 字符串
  if ( my $extensions = delete $format_config->{'from-extensions'} ) {
    if ( ref $extensions eq 'ARRAY' && @$extensions ) {
      $format_config->{from} = 'markdown+' . join( '+', @$extensions );
    }
  }

  return $format_config;
}

sub _extract_pandoc_options {
  my ($format_config) = @_;

  # 排除 fexport 专用的 key
  my %fexport_keys = map { $_ => 1 } qw(ext intermediate intermediate_ext from-extensions);

  return {
    map  { $_ => $format_config->{$_} }
    grep { !$fexport_keys{$_} }
      keys %$format_config
  };
}

# ============================================================================
# 路径计算
# ============================================================================

sub _calculate_local_outfile {
  my ( $infile, $final_dest, $quarto_target_ext, $outformat ) = @_;

  # 为了解决 Quarto embed-resources 找不到资源文件的问题
  # 我们需要将临时输出文件放在与输入文件相同的目录中
  my $local_outfile = $infile->parent->child( $final_dest->basename );

  # 如果是中间格式，需要替换扩展名
  if ( $quarto_target_ext ne $outformat ) {
    my $base = $local_outfile->basename(qr/\.[^.]+$/);
    $local_outfile = $local_outfile->parent->child( $base . "." . $quarto_target_ext );
  }

  return $local_outfile;
}

# ============================================================================
# 元数据处理
# ============================================================================

sub _prepare_metadata {
  my ( $format_config, $backup_file ) = @_;

  my $default_meta = _extract_pandoc_options($format_config);

  return $default_meta unless $backup_file->exists;

  my $meta_data = LoadFile($backup_file);
  _merge_yaml( $meta_data, $default_meta );
  return $meta_data;
}

sub _resolve_template_path {
  my ( $meta_data, $quarto_target ) = @_;

  # Return early if no template is specified or if it's already an absolute path
  return unless exists $meta_data->{template};
  return if path( $meta_data->{template} )->is_absolute;

  # Append file extension if not present
  my $tmpl_name = $meta_data->{template};
  $tmpl_name .= ".${quarto_target}" unless $tmpl_name =~ /\.\w+$/;

  # Define template search paths
  my $local_tmpl  = path($tmpl_name);                                 # Current working directory
  my $pandoc_tmpl = $PANDOC_DIR->child( "templates", $tmpl_name );    # ~/.pandoc/templates/

  # Resolve template path by checking existence in order of precedence
  if ( $local_tmpl->exists ) {
    $meta_data->{template} = $local_tmpl->absolute->stringify;
  }
  elsif ( $pandoc_tmpl->exists ) {
    $meta_data->{template} = $pandoc_tmpl->absolute->stringify;
  }
  elsif ( $meta_data->{template} !~ /^\s*default\s*$/ ) {

    # Throw error if template not found and not using 'default'
    die "Error: Template file '$tmpl_name' not found.\n"
      . "Searched in:\n"
      . "  1. Current Directory: "
      . path('.')->absolute . "\n"
      . "  2. Pandoc Directory:  "
      . $PANDOC_DIR->child("templates") . "\n";
  }

  return;
}

# ============================================================================
# Quarto 执行
# ============================================================================

sub _run_quarto_with_metadata {
  my %args = @_;
  my ( $infile, $format_config, $quarto_target, $local_outfile, $lang, $verbose ) =
    @args{qw(infile format_config quarto_target local_outfile lang verbose)};

  # 切换工作目录到 input file 所在目录
  # 这是为了解决 Quarto embed-resources 在 CWD 查找资源的问题
  my $start_dir = getcwd();
  my $work_dir  = $infile->parent;
  chdir $work_dir or die "Cannot chdir to $work_dir: $!";

  my $meta_file      = $work_dir->child("_metadata.yml");    # path relative to new CWD (or abs) - Path::Tiny handles it
  my $backup_file    = $work_dir->child("_metadata.yml_bck");
  my $generated_meta = 0;

  # Guard: 离开作用域时自动清理/恢复
  my $guard = guard {
    if ( $generated_meta && $meta_file->exists ) {
      $meta_file->remove;
    }
    if ( $backup_file->exists ) {
      $backup_file->move($meta_file);
    }
    chdir $start_dir;    # 恢复工作目录
  };

  # 备份现有 _metadata.yml
  $meta_file->move($backup_file) if $meta_file->exists;

  # 准备元数据
  my $meta_data = _prepare_metadata( $format_config, $backup_file );
  _resolve_template_path( $meta_data, $quarto_target );

  # 设置语言
  $lang //= $meta_data->{lang};
  $meta_data->{lang} = $lang;

  # 写入临时 _metadata.yml
  DumpFile( $meta_file->stringify, $meta_data );
  $generated_meta = 1;

  # 构建并执行 Quarto 命令
  # 注意：此时 CWD 已经是 input dir，所以 execute-dir 为 .
  my @cmd = _build_quarto_command( $infile->basename, $quarto_target, $local_outfile, $meta_data, $verbose );

  print encode_utf8( CYAN . "🚀 Running Quarto render..." . RESET . "\n" );
  print FAINT, "   Command: ", join( " ", @cmd ), "\n", RESET if $verbose;

  system(@cmd) == 0 or die encode_utf8( RED . "❌ Failed to run quarto: $?" . RESET );

  print encode_utf8( GREEN . "✅ Intermediate output created: " . $local_outfile->basename . RESET . "\n" );

  return $lang;
}

sub _build_quarto_command {
  my ( $infile_name, $quarto_target, $local_outfile, $meta_data, $verbose ) = @_;

  # Base command array with required arguments
  # infile_name 只传文件名，因为我们在 input 目录下运行
  my @cmd = (
    "quarto",   "render", $infile_name, "--to=$quarto_target", "--execute-dir", ".",
    "--output", $local_outfile->basename,
  );

  # 如果不是 verbose 模式，让 Quarto 保持安静 (不打印 Pandoc 参数 dump)
  push @cmd, "--quiet" unless $verbose;

  # Add Lua filters for document processing
  if ( $quarto_target eq 'docx' ) {
    push @cmd, "--lua-filter", $PANDOC_DIR->child("filters/quarto_docx_embeded_table.lua")->stringify;
  }

  push @cmd, "--lua-filter", $PANDOC_DIR->child("filters/rsbc.lua")->stringify;

  # Explicitly pass pdf-engine if specified in metadata
  if ( my $pdf_engine = $meta_data->{'pdf-engine'} ) {
    push @cmd, "--pdf-engine=$pdf_engine";
  }

  return @cmd;
}

# ============================================================================
# 后处理分发
# ============================================================================

sub _dispatch_postprocess {
  my %args = @_;
  my ( $outformat, $local_outfile, $final_dest, $infile, $lang, $preview, $verbose, $keep, $browser ) =
    @args{qw(outformat local_outfile final_dest infile lang preview verbose keep browser)};

  if ( $outformat eq "html" ) {
    _process_html_output( $local_outfile, $preview, $final_dest, $browser );
    $local_outfile->remove if $local_outfile->absolute ne $final_dest->absolute;
  }
  elsif ( $outformat eq "pdf" ) {
    _process_pdf_output( $local_outfile, $verbose, $keep, $final_dest, $infile );
    $local_outfile->remove if $local_outfile->exists && !$keep;
  }
  elsif ( $outformat eq "docx" ) {
    _process_docx_output( $local_outfile, $lang );
    $local_outfile->move($final_dest);
  }
  else {
    # 默认：直接移动
    $local_outfile->move($final_dest) if $local_outfile->absolute ne $final_dest->absolute;
  }
}

# ============================================================================
# 格式特定后处理
# ============================================================================

sub _process_html_output {
  my ( $infile, $preview, $outfile_dest, $browser ) = @_;

  my @lines = $infile->lines_utf8();
  fix_citation_etal( \@lines );
  postprocess_html( \@lines );

  path($outfile_dest)->spew_utf8(@lines);
  print encode_utf8( BOLD . GREEN . "✨ HTML generated: $outfile_dest" . RESET . "\n" );
  launch_browser_preview( $outfile_dest, $browser ) if $preview;
}

sub _process_pdf_output {
  my ( $tex_file, $verbose, $keep, $final_pdf_dest, $infile ) = @_;

  # Quarto Book 项目可能输出到 _book/ 子目录
  $tex_file = _find_tex_file( $tex_file, $infile );
  die "Error: TeX file '$tex_file' not found." unless $tex_file->exists;

  # 读取并后处理 TeX 内容
  my @lines = $tex_file->lines_utf8;
  postprocess_latex( \@lines, $infile->parent );

  # 临时编译目录
  my $temp_dir = Path::Tiny->tempdir( CLEANUP => !$keep );
  say "Intermediate files kept in: $temp_dir" if $keep;

  my $temp_tex = $temp_dir->child("intermediate.tex");
  $temp_tex->spew_utf8(@lines);

  # 执行 latexmk
  my @cmd =
    ( 'latexmk', '-xelatex', "-outdir=" . $temp_dir->stringify, $verbose ? () : '-quiet', $temp_tex->stringify );

  if ($verbose) {
    print encode_utf8( CYAN . "⚙️  Compiling PDF with latexmk..." . RESET . "\n" );
    system(@cmd) == 0 or die RED "❌ Failed to render LaTeX file: $?";
  }
  else {
    # Fork a child process to show a spinner
    my $spinner_pid = fork;
    if ( defined $spinner_pid && $spinner_pid == 0 ) {

      # Child process: show spinner
      $| = 1;    # Autoflush
      binmode( STDOUT, ":utf8" );
      local $SIG{TERM} = sub { exit 0 };
      my @chars = qw(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏);
      my $i     = 0;
      print CYAN . "⚙️  Compiling PDF with latexmk... " . RESET;
      while (1) {
        print "\b" . $chars[ $i++ % @chars ];
        select( undef, undef, undef, 0.1 );    # Sleep 0.1s
      }
      exit 0;
    }

    my $output;

    # Capture both stdout and stderr
    run3 \@cmd, \undef, \$output, \$output;
    my $exit_code = $?;

    # Kill spinner
    if ( defined $spinner_pid ) {
      kill 'TERM', $spinner_pid;
      waitpid( $spinner_pid, 0 );
      print "\r" . ( " " x 40 ) . "\r";    # Clear line
    }

    if ( $exit_code != 0 ) {
      die encode_utf8( RED . "❌ Failed to render LaTeX file:\n$output" . RESET );
    }
  }

  # 移动结果
  my $generated_pdf = $temp_dir->child("intermediate.pdf");
  if ( $generated_pdf->exists ) {
    $generated_pdf->move($final_pdf_dest);
    print encode_utf8( BOLD . GREEN . "✨ PDF generated: $final_pdf_dest" . RESET . "\n" );
  }
  else {
    die RED "❌ Error: latexmk finished but PDF not found.";
  }
}

sub _find_tex_file {
  my ( $tex_file, $infile ) = @_;

  return $tex_file if $tex_file->exists;

  # 尝试 _book/ 目录 (Quarto Book 项目)
  my $book_tex = path("_book")->child( $tex_file->basename );
  return $book_tex if $book_tex->exists;

  # 尝试输入文件父目录的 _book/
  if ( defined $infile ) {
    $book_tex = $infile->parent->child("_book")->child( $tex_file->basename );
    return $book_tex if $book_tex->exists;
  }

  return $tex_file;    # 返回原始路径，让调用者处理错误
}

sub _process_docx_output {
  my ( $docx_file, $lang ) = @_;
  postprocess_docx( $docx_file->stringify ) if $lang eq 'zh';
}

# ============================================================================
# 通用工具函数
# ============================================================================

sub _substitute_env {
  my ($data) = @_;
  return unless defined $data;

  my $ref = ref $data;

  # Handle scalar: substitute environment variables in-place
  # Matches $VAR or ${VAR} and replaces with ENV value or empty string
  if ( !$ref ) {
    $_[0] =~ s/\$\{?(\w+)\}?/exists $ENV{$1} ? $ENV{$1} : ''/eg;
  }

  # Handle hash: recursively substitute values
  elsif ( $ref eq 'HASH' ) {
    _substitute_env($_) for values %$data;
  }

  # Handle array: recursively substitute elements
  elsif ( $ref eq 'ARRAY' ) {
    _substitute_env($_) for @$data;
  }

  # Handle scalar reference: dereference and substitute
  elsif ( $ref eq 'SCALAR' ) {
    _substitute_env($$data);
  }

  return;
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
      $dest->{$key} = $val_src;
    }
  }
}

1;
