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
use POSIX           qw(setsid);
use IPC::Cmd        qw(can_run);
use Term::ANSIColor qw(:constants);
$Term::ANSIColor::AUTORESET = 1;

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
  my ( $stderr_bytes, $stdout_bytes );
  run3 $cmd_ref, \$stdin_data, \$stdout_bytes, \$stderr_bytes;
  if ( defined $stdout_bytes ) {
    binmode STDOUT;    # 临时切回二进制模式打印原始字节
    print $stdout_bytes;
  }

  # 4. 错误检查
  if ( $? != 0 ) {

    # $? >> 8 获取真实退出码
    my $exit_code = $? >> 8;
    print $stderr_bytes;
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
    my $content = $pid_file->slurp_utf8;
    my ($pid) = split( /\n/, $content, 2 );
    chomp $pid if defined $pid;

    if ( $pid && $pid =~ /^\d+$/ && kill( 0, $pid ) ) {
      say "[Preview] Browser-sync is already running (PID: $pid).";
      say "[Preview] Browser should auto-refresh shortly.";
      return;
    }
    else {
      $pid_file->remove;
    }
  }

  # 4. 启动新的后台进程
  say encode_utf8( "\n" . BOLD . "⏳ Starting browser-sync in background..." . RESET );

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
  # Save PID and Server Path for identification
  $pid_file->spew_utf8("$pid\n$server_dir");

  say encode_utf8( "\n" . BOLD . GREEN . "✅ Preview Server started" . RESET . " (PID: $pid)" );
  say encode_utf8( "   📂 Serving:  " . CYAN . $server_dir . RESET );
  say encode_utf8( "   💡 Control:  " . YELLOW . "fexport --stop-preview" . RESET );

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
    say encode_utf8( "\n" . YELLOW . "ℹ️  No active preview servers found." . RESET );
    return;
  }

  my @pid_files = $state_dir->children(qr/^preview-.*\.pid$/);

  if ( @pid_files == 0 ) {
    say encode_utf8( "\n" . YELLOW . "ℹ️  No active preview servers found." . RESET );
    return;
  }

  my @active_previews;

  # 1. Collect active previews
  for my $pid_file (@pid_files) {
    my $content = $pid_file->slurp_utf8;
    my ( $pid, $path ) = split( /\n/, $content, 2 );
    chomp $pid  if defined $pid;
    chomp $path if defined $path;

    # Fallback for old PID files (only PID)
    $path //= "Unknown Path";

    if ( $pid && kill( 0, $pid ) ) {
      push @active_previews,
        {
          pid      => $pid,
          path     => $path,
          pid_file => $pid_file
        };
    }
    else {
      # cleanup stale pid file
      $pid_file->remove;
    }
  }

  if ( @active_previews == 0 ) {
    say encode_utf8( "\n" . YELLOW . "ℹ️  No active preview servers found." . RESET );
    return;
  }

  my @to_stop;

  # 2. Determine what to stop
  if ( @active_previews == 1 ) {
    @to_stop = @active_previews;
  }
  else {
    # Interactive selection
    say "\n[Preview] Multiple preview servers are running:";
    for my $i ( 0 .. $#active_previews ) {
      my $p = $active_previews[$i];
      printf "  [%d] PID: %-6s Path: %s\n", $i + 1, $p->{pid}, $p->{path};
    }
    say "  [a] Stop ALL";
    say "  [c] Cancel";

    print "\nSelect instance(s) to stop [1-${\scalar(@active_previews)}, a, c]: ";
    my $choice = <STDIN>;
    chomp $choice;

    if ( lc($choice) eq 'a' ) {
      @to_stop = @active_previews;
    }
    elsif ( lc($choice) eq 'c' || $choice eq '' ) {
      say "[Preview] Operation cancelled.";
      return;
    }
    elsif ( $choice =~ /^\d+$/ && $choice >= 1 && $choice <= @active_previews ) {
      push @to_stop, $active_previews[ $choice - 1 ];
    }
    else {
      say "[Preview] Invalid selection.";
      return;
    }
  }

  # 3. Stop selected
  my $stopped_count = 0;
  for my $item (@to_stop) {
    my $pid = $item->{pid};
    if ( kill( 'TERM', $pid ) ) {
      say encode_utf8( "🛑 " . BOLD . RED . "Stopped" . RESET . " preview server (PID: $pid)" );
      say encode_utf8( "   📂 Path: " . CYAN . $item->{path} . RESET );
      $item->{pid_file}->remove;

      # Clean log file (derive name from pid filename)
      # pid file: preview-HASH.pid -> log file: preview-HASH.log
      my $log_file = $item->{pid_file}->parent->child( $item->{pid_file}->basename =~ s/\.pid$/.log/r );
      $log_file->remove if $log_file->exists;

      $stopped_count++;
    }
    else {
      warn "[Preview] Failed to stop PID $pid: $!\n";
    }
  }

  say encode_utf8( "\n" . BOLD . GREEN . "✅ Stopped $stopped_count preview server(s)." . RESET ) if $stopped_count > 0;
}

1;
