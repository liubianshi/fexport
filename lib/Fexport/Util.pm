package Fexport::Util;

use v5.20;
use strict;
use warnings;
use utf8;
use Exporter 'import';

# 核心依赖
# 核心依赖
use IPC::Run3 qw(run3);
use Path::Tiny;
use File::ShareDir qw(dist_file);
use FindBin        qw($RealBin);
use Digest::MD5    qw(md5_hex);
use File::Spec;
use POSIX    qw(setsid);
use IPC::Cmd qw(can_run);

# 导出函数名更新
our @EXPORT_OK = qw(
  run_pandoc
  run_pandoc_and_load
  save_lines
  find_pandoc_datadir
  find_resource
  launch_browser_preview
  stop_browser_preview
  run3
);

# ==============================================================================
# 1. Pandoc 执行相关
# ==============================================================================

use Encode qw(encode_utf8);    # Ensure Encode is used

# ...

# 作用: 将内容写入 Pandoc 的 STDIN 并执行
sub run_pandoc {
  my ( $content_lines_ref, $cmd_ref, $log_fh ) = @_;

  # 1. 记录日志 (调试用) - Log is opened as :raw, so must encode text
  if ($log_fh) {

    # Encode command string to bytes
    my $cmd_str = join( " ", @$cmd_ref );
    say {$log_fh} encode_utf8($cmd_str);
  }

  # 2. 准备输入数据
  # 将数组行(字符)合并并编码为 UTF-8 字节流，供 Pandoc STDIN 使用
  my $stdin_data = encode_utf8( join( "", @$content_lines_ref ) );

  # 3. 安全执行命令 (IPC::Run3)
  # 捕获 STDERR 到 scalar (字节)，然后手动写入 log，避免 IPC::Run3 直接写 handle 可能的 warn
  my $stderr_bytes;

  run3 $cmd_ref, \$stdin_data, \undef, \$stderr_bytes;

  if ( $log_fh && defined $stderr_bytes ) {
    print {$log_fh} $stderr_bytes;
  }

  # 4. 错误检查
  if ( $? != 0 ) {

    # $? >> 8 获取真实退出码
    my $exit_code = $? >> 8;
    die "Error: Pandoc exited with code $exit_code. Check logs for details.\n";
  }

  return 1;    # 成功返回真值
}

# 作用: 运行 Pandoc 生成文件，然后立即把生成的文件读回内存
# 优化: 不再通过参数引用(@$out)返回数据，而是直接 return 数组
sub run_pandoc_and_load {
  my ( $in_lines_ref, $cmd_ref, $outfile, $log_fh ) = @_;

  # 1. 执行转换
  run_pandoc( $in_lines_ref, $cmd_ref, $log_fh );

  # 2. 读取结果
  # 使用 Path::Tiny 对象
  my $file = path($outfile);

  if ( $file->exists ) {

    # 优化: 使用 lines_utf8 确保编码正确
    # chomp => 0 保留换行符，与原逻辑保持一致
    return $file->lines_utf8( { chomp => 0 } );
  }
  else {
    warn "Warning: Expected output file '$outfile' was not created by pandoc.\n";
    return ();
  }
}

# ==============================================================================
# 2. 文件 I/O
# ==============================================================================

# 作用: 将数组行写入文件
sub save_lines {
  my ( $lines_ref, $outfile ) = @_;

  # 优化: 使用 spew_utf8 自动处理编码
  path($outfile)->spew_utf8( join( "", @$lines_ref ) );
}

# ==============================================================================
# 3. 资源与配置查找
# ==============================================================================

sub find_pandoc_datadir {
  state $datadir;
  return $datadir if defined $datadir;

  # 1. 尝试通过 pandoc --version 获取
  # 使用 IPC::Run3 或 qx 安全调用? qx 对于 simple command 尚可
  my $output = qx(pandoc --version);

  if ( $output && $output =~ /User data directory:\s*([^\s]+)/m ) {
    $datadir = $1;
  }
  else {
    # 2. 失败回退: 检查默认目录 ~/.pandoc
    my $default_path = path( $ENV{HOME} )->child(".pandoc");
    $datadir = $default_path->is_dir ? $default_path->stringify : "";
  }

  return $datadir;
}

# 作用: 在开发目录、ShareDir、脚本同级目录查找文件
sub find_resource {
  my $filename = shift;

  # 1. 开发环境/本地路径 (../share)
  my $local = path($RealBin)->parent->child( "share", $filename );
  return $local->absolute->stringify if $local->exists;

  # 2. 发行版安装路径 (File::ShareDir)
  # 使用 eval 捕获可能的错误 (如未安装)
  my $dist_path;
  eval { $dist_path = dist_file( 'fexport', $filename ); };
  return $dist_path if defined $dist_path && -e $dist_path;

  # 3. 遗留/平铺路径 (脚本同级)
  my $legacy = path($RealBin)->child($filename);
  return $legacy->absolute->stringify if $legacy->exists;

  warn "Warning: Resource file '$filename' not found in share directory or local path.\n";
  return undef;
}

# ==============================================================================
# 4. Preview / Browser Sync
# ==============================================================================

sub launch_browser_preview {
  my ( $target_file, $browser ) = @_;

  # 1. 检查是否安装了 browser-sync
  unless ( can_run('browser-sync') ) {
    warn "[Warn] 'browser-sync' not found. Skipping live preview.\n";
    return;
  }

  my $file_obj   = path($target_file)->realpath;    # Normalize path (removes ../ etc)
  my $server_dir = $file_obj->parent;

  # 2. 计算 PID 文件位置 (存放于系统临时目录)
  # 算法：系统Temp目录 / fexport-state / <项目路径的MD5>.pid
  my $dir_hash  = md5_hex( $server_dir->stringify );
  my $sys_tmp   = path( File::Spec->tmpdir );
  my $state_dir = $sys_tmp->child("fexport-state");
  $state_dir->mkpath;
  my $pid_file = $state_dir->child("preview-$dir_hash.pid");

  # 3. 检查是否已经在运行 (PID 检查逻辑)
  if ( $pid_file->exists ) {
    my $pid = $pid_file->slurp;
    chomp $pid;

    if ( $pid && kill( 0, $pid ) ) {
      say "[Preview] Browser-sync is already running (PID: $pid).";
      say "[Preview] Browser should auto-refresh shortly.";
      return;
    }
    else {
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
    setsid() or die "Can't start a new session: $!";

    # Log file for debugging browser-sync issues
    my $log_file = $state_dir->child("preview-$dir_hash.log");

    open STDIN,  '<',  '/dev/null';
    open STDOUT, '>>', $log_file->stringify;
    open STDERR, '>&', \*STDOUT;

    my $index_file    = $file_obj->basename;
    my $watch_pattern = $server_dir->child("*.html")->stringify;    # Absolute path pattern
    my @cmd           = (
      'browser-sync', 'start',
      '--server',     $server_dir->stringify,
      '--index',      $index_file,
      '--files',      $watch_pattern,
      '--no-open',    # Don't open browser from daemon (it can't access display)
      '--no-notify',
      '--no-ui',
      '--port', '3000'
    );

    exec(@cmd) or die "Failed to exec browser-sync: $!";
  }

  # === 父进程 (Parent) ===
  $pid_file->spew($pid);

  say "[Preview] Server started with PID $pid.";
  say "[Preview] Serving from: $server_dir";
  say "[Preview] To stop it manually: fexport --stop-preview";

  # Wait a moment for server to start, then open browser from parent (has display access)
  sleep 1;
  my $url = "http://localhost:3000";

  # Fork to open browser in background so script can exit immediately
  my $browser_pid = fork();
  if ( defined $browser_pid && $browser_pid == 0 ) {

    # Child process - open browser and exit
    if ($browser) {
      exec( $browser, $url );
    }
    elsif ( $^O eq 'darwin' ) {
      exec( 'open', $url );
    }
    elsif ( $^O eq 'linux' ) {
      exec( 'xdg-open', $url );
    }
    elsif ( $^O eq 'MSWin32' ) {
      exec( 'start', $url );
    }
    exit 0;
  }

  # Parent continues and exits
}

sub stop_browser_preview {
  my $sys_tmp   = path( File::Spec->tmpdir );
  my $state_dir = $sys_tmp->child("fexport-state");

  unless ( $state_dir->is_dir ) {
    say "[Preview] No preview servers are running.";
    return;
  }

  my @pid_files = $state_dir->children(qr/^preview-.*\.pid$/);

  if ( @pid_files == 0 ) {
    say "[Preview] No preview servers are running.";
    return;
  }

  my $stopped = 0;
  for my $pid_file (@pid_files) {
    my $pid = $pid_file->slurp;
    chomp $pid;

    if ( $pid && kill( 0, $pid ) ) {

      # Process exists, kill it
      if ( kill( 'TERM', $pid ) ) {
        say "[Preview] Stopped browser-sync (PID: $pid).";
        $stopped++;
      }
      else {
        warn "[Preview] Failed to stop PID $pid: $!\n";
      }
    }

    # Remove PID file regardless
    $pid_file->remove;
  }

  # Also clean up log files
  for my $log_file ( $state_dir->children(qr/^preview-.*\.log$/) ) {
    $log_file->remove;
  }

  if ( $stopped == 0 ) {
    say "[Preview] No active preview servers found.";
  }
  else {
    say "[Preview] Stopped $stopped preview server(s).";
  }
}

1;
