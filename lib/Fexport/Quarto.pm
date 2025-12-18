package Fexport::Quarto;

use v5.20;
use strict;
use warnings;
use Exporter 'import';

# 核心依赖更新
use Path::Tiny;
use Digest::MD5 qw(md5_hex);
use File::Spec;
use YAML         qw(LoadFile DumpFile);
use Scope::Guard qw(guard);
use List::Util   qw(uniq);
use IPC::Run3    qw(run3);                # 用于捕获 xdotool 输出等
use List::Util   qw(uniq);
use POSIX        qw(setsid);
use IPC::Cmd     qw(can_run);

use Fexport::Util        qw(save_lines find_resource find_pandoc_datadir);
use Fexport::PostProcess qw(fix_citation_etal postprocess_html postprocess_latex postprocess_docx);

our @EXPORT_OK = qw(render_qmd);

# 常量定义
my $PANDOC_DIR = path( find_pandoc_datadir() );

sub render_qmd {
  my ( $infile_raw, $outformat, $outfile_final, $lang, $preview, $verbose, $keep_intermediates, $outfile_abs_path ) =
    @_;

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
  # 使用 Scope::Guard 确保 _metadata.yml 无论如何都会恢复
  {
    my $meta_file      = path("_metadata.yml");
    my $backup_file    = path("_metadata.yml_bck");
    my $generated_meta = 0;

    my $guard = guard {
      $meta_file->remove             if $generated_meta;
      $backup_file->move($meta_file) if $backup_file->exists;
    };

    if ( $meta_file->exists ) {
      $meta_file->move($backup_file);
    }

    # 加载 Pandoc Defaults 并合并
    my $defaults_path = $PANDOC_DIR->child( "defaults", "2${quarto_target}.yaml" );
    my $meta_data     = _load_pandoc_defaults($defaults_path);

    if ( $backup_file->exists ) {
      my $existing_meta = LoadFile($backup_file);
      _merge_yaml( $meta_data, $existing_meta );
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
      "quarto",                                                               "render",
      $infile->stringify,                                                     "--to",
      $quarto_target,                                                         "--output",
      $local_outfile->stringify,                                              "--lua-filter",
      $PANDOC_DIR->child("filters/quarto_docx_embeded_table.lua")->stringify, "--lua-filter",
      $PANDOC_DIR->child("filters/rsbc.lua")->stringify
    );

    # 使用列表 system，安全
    system(@quarto_cmd) == 0 or die "Failed to run quarto: $?";

    # Guard 会在离开此块时自动执行清理恢复
  }

  # 6. 后处理与移动 (Post-process & Move)
  if ( $outformat eq "html" ) {
    _process_html_output( $local_outfile, $preview, $final_dest );

    # HTML 处理完后，如果 local_outfile 和 final_dest 不一样，清理 local
    $local_outfile->remove if $local_outfile->absolute ne $final_dest->absolute;
  }
  elsif ( $outformat eq "pdf" ) {
    _process_pdf_output( $local_outfile, $verbose, $keep_intermediates, $final_dest );

    # PDF 处理函数内部会移动文件，这里只需清理 tex
    $local_outfile->remove unless $keep_intermediates;
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
  my ( $infile, $preview, $outfile_dest ) = @_;

  # 模拟原来的数组引用接口
  my @lines = $infile->lines_utf8();

  fix_citation_etal( \@lines );
  postprocess_html( \@lines );

  # 写入最终位置
  path($outfile_dest)->spew_utf8(@lines);

  _launch_browser_preview($outfile_dest) if $preview;
}

sub _launch_browser_preview {
  my ($target_file) = @_;

  # 1. 检查是否安装了 browser-sync
  unless ( can_run('browser-sync') ) {
    warn "[Warn] 'browser-sync' not found. Skipping live preview.\n";
    return;
  }

  my $file_obj   = path($target_file);
  my $server_dir = $file_obj->parent->absolute;

  # 2. 计算 PID 文件位置 (存放于系统临时目录)
  # 算法：系统Temp目录 / fexport-state / <项目路径的MD5>.pid
  # 这样每个项目目录都有唯一的 PID 文件，互不冲突，且不污染源码目录。
  my $dir_hash  = md5_hex( $server_dir->stringify );
  my $sys_tmp   = path( File::Spec->tmpdir );          # Linux通常是 /tmp, Windows是 %TEMP%
  my $state_dir = $sys_tmp->child("fexport-state");
  $state_dir->mkpath;
  my $pid_file = $state_dir->child("preview-$dir_hash.pid");

  # 3. 检查是否已经在运行 (PID 检查逻辑)
  if ( $pid_file->exists ) {
    my $pid = $pid_file->slurp;
    chomp $pid;

    # 使用 kill 0 检查进程是否存在且有权限操作 (不发送实际信号)
    if ( $pid && kill( 0, $pid ) ) {
      say "[Preview] Browser-sync is already running (PID: $pid).";
      say "[Preview] Browser should auto-refresh shortly.";
      return;    # 直接返回，主程序随后会退出
    }
    else {
      # PID 文件存在但进程不在了 (Stale lock)，清理掉
      $pid_file->remove;
    }
  }

  # 4. 启动新的后台进程
  say "[Preview] Starting browser-sync in background...";

  my $pid = fork();
  if ( !defined $pid ) {
    warn "Failed to fork: $!";
    return;
  }

  if ( $pid == 0 ) {

    # === 子进程 (Child) ===

    # A. 创建新的会话，脱离控制终端
    setsid() or die "Can't start a new session: $!";

    # B. 重定向输入输出，防止阻塞父进程或干扰终端
    open STDIN,  '<', '/dev/null';
    open STDOUT, '>', '/dev/null';    # 或者重定向到日志文件
    open STDERR, '>', '/dev/null';

    # C. 准备命令
    my $index_file = $file_obj->basename;
    my @cmd        = (
      'browser-sync', 'start',
      '--server',     $server_dir->stringify,
      '--index',      $index_file,
      '--files',      $target_file,             # 监听特定文件
      '--no-notify',                            # 不显示右上角弹窗
      '--ui',   'false',                        # 不启动 UI 控制面板
      '--port', '3000'                          # 尽量固定端口，避免多开混乱
    );

    # D. 执行命令 (exec 会替换当前子进程内存，PID 保持不变)
    exec(@cmd) or die "Failed to exec browser-sync: $!";
  }

  # === 父进程 (Parent) ===

  # 4. 记录 PID 到文件，以便下次检查
  $pid_file->spew($pid);

  say "[Preview] Server started with PID $pid.";
  say "[Preview] To stop it manually: kill $pid";
}

sub _process_pdf_output {
  my ( $tex_file, $verbose, $keep, $final_pdf_dest ) = @_;

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

1;
