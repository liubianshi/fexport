package Fexport::Config;

use v5.20;
use strict;
use warnings;
use Exporter 'import';
use YAML::XS qw(LoadFile);
use Path::Tiny;

our @EXPORT_OK = qw(load_config merge_config process_params);

use Fexport::Util qw(find_resource);

# Load Global Defaults from YAML file
sub _load_defaults {
  my $defaults_file = find_resource("defaults.yaml");
  return {} unless defined $defaults_file && -f $defaults_file;

  my $raw = eval { LoadFile($defaults_file) };
  if ($@) {
    warn "[Warn] Failed to load defaults file: $@";
    return {};
  }

  # Convert hyphenated keys to underscored keys recursively
  return _convert_keys($raw);
}

sub _convert_keys {
  my ($data) = @_;
  return $data unless ref $data;

  if ( ref $data eq 'HASH' ) {
    my %converted;
    for my $key ( keys %$data ) {
      my $new_key = $key;
      $new_key =~ s/-/_/g;    # user-opts -> user_opts
      $converted{$new_key} = _convert_keys( $data->{$key} );
    }
    return \%converted;
  }
  elsif ( ref $data eq 'ARRAY' ) {
    return [ map { _convert_keys($_) } @$data ];
  }

  return $data;
}

# Cache loaded defaults
my $DEFAULTS;

sub _get_defaults {
  $DEFAULTS //= _load_defaults();
  return $DEFAULTS;
}

sub load_config {
  my ($file) = @_;

  # 增加 -f 判断确保是文件
  return {} unless defined $file && -f $file;

  # eval 捕获异常是个好习惯
  my $config = eval { LoadFile($file) };
  if ($@) {
    warn "[Warn] Failed to load config file '$file': $@";
    return {};
  }
  return _convert_keys($config);
}

sub merge_config {
  my ( $file_config, $cli_opts ) = @_;

  # 链式合并：Defaults -> File -> CLI
  my $merged = _get_defaults();

  $merged = _recursive_merge( $merged, $file_config ) if $file_config;
  $merged = _recursive_merge( $merged, $cli_opts )    if $cli_opts;

  return $merged;
}

sub process_params {
  my ( $opts, $infile_raw, $current_pwd ) = @_;

  # 0. 初始化基础路径对象
  my $cwd = path( $current_pwd // '.' )->absolute;

  # Fix: use path()->absolute() because $cwd->child() concatenates even if argument is absolute path string
  my $infile_abs = defined $infile_raw ? path($infile_raw)->absolute($cwd) : undef;

  # 1. 确定工作目录 (Effective Working Directory)
  # 自动判断：如果输入文件是绝对路径，使用文件所在目录；如果是相对路径，使用当前目录
  my $work_dir;

  if ( $opts->{workdir} ) {
    # 用户显式指定了工作目录
    $work_dir = $cwd->child( $opts->{workdir} );
  }
  elsif ( defined $infile_raw && path($infile_raw)->is_absolute ) {
    # 输入文件是绝对路径 -> 使用文件所在目录
    $work_dir = $infile_abs->parent;
  }
  else {
    # 输入文件是相对路径或未指定 -> 使用当前目录
    $work_dir = $cwd;
  }

  # 2. 计算输入文件的相对路径 (相对于将要 chdir 的目录)
  my $resolved_infile = $infile_abs ? $infile_abs->relative($work_dir) : undef;

  # 3. 推断格式
  $opts->{from} //= ( $resolved_infile && $resolved_infile =~ /\.([^.]+)$/ ? $1 : undef ) || 'md';
  $opts->{to}   //= "html";

  # 4. 确定最终输出文件路径 (修正后的逻辑)
  # 逻辑核心：如果存在 outdir，则 outfile 被视为基于 outdir 的相对路径
  my $abs_outfile;

  # 场景 A: 显式指定 outdir
  if ( defined $opts->{outdir} ) {
    my $base_out = $cwd->child( $opts->{outdir} );

    if ( defined $opts->{outfile} ) {
      my $outfile_path = path( $opts->{outfile} );
      if ( $outfile_path->is_absolute ) {
        $abs_outfile = $outfile_path;
      }
      else {
        $abs_outfile = $base_out->child( $outfile_path->basename );
      }
    }
    elsif ($resolved_infile) {
      my $name = $resolved_infile->basename(qr/\.[^.]+$/) . '.' . $opts->{to};
      $abs_outfile = $base_out->child($name);
    }
    else {
      $abs_outfile = $base_out->child( "output." . $opts->{to} );
    }
  }

  # 场景 B: 未指定 outdir, 但指定了 outfile
  elsif ( defined $opts->{outfile} ) {
    my $outfile_path = path( $opts->{outfile} );
    if ( $outfile_path->is_absolute ) {
      $abs_outfile = $outfile_path;
    }
    else {
      # 用户提供的 outfile 相对于 cwd.
      $abs_outfile = $cwd->child( $opts->{outfile} );
    }
  }

  # 场景 C: 默认输出到 work_dir
  else {
    my $base_out = $work_dir;
    my $name =
        $resolved_infile
      ? $resolved_infile->basename(qr/\.[^.]+$/) . '.' . $opts->{to}
      : "output." . $opts->{to};
    $abs_outfile = $base_out->child($name);
  }

  # 5. 返回相对于 work_dir 的路径 (因为脚本后续会 chdir 到 work_dir)
  my $rel_outfile = $abs_outfile->relative($work_dir);

  # 返回字符串路径 (显式 stringify 避免对象泄露给不识别 Path::Tiny 的旧代码)
  return ( "$work_dir", "$resolved_infile", "$rel_outfile" );
}

# Removed Hash::Merge dependency due to global state issues.
# Implementing simple recursive merge (Right replace arrays/scalars, Merge hashes)
sub _recursive_merge {
  my ( $left, $right ) = @_;
  return $right unless defined $left;
  return $left  unless defined $right;

  if ( ref($left) eq 'HASH' && ref($right) eq 'HASH' ) {
    my %merged = %$left;
    for my $key ( keys %$right ) {
      my $l_val = ( exists $left->{$key} ) ? $left->{$key} : undef;
      $merged{$key} = _recursive_merge( $l_val, $right->{$key} );
    }
    return \%merged;
  }

  # For arrays and scalars, Right wins (Replacement)
  return $right;
}

1;

