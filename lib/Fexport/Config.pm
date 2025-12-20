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

  # 提取 _defaults 部分作为 fexport 默认值基础
  my $fexport_defaults = delete $raw->{_defaults} // {};
  
  # 提取 pandoc 配置
  my $pandoc_config = $raw->{pandoc} // {};
  
  # 从 _markdown.extensions 构建 markdown-fmt 字符串
  my $extensions = $raw->{_markdown}{extensions};
  my @exts_list  = ( defined $extensions && ref($extensions) eq 'ARRAY' ) ? @$extensions : ();
  
  $pandoc_config->{'markdown-fmt'} = join( '+', 'markdown', @exts_list );
  

  # 合并: fexport 默认值 + pandoc 配置
  $fexport_defaults->{pandoc} = $pandoc_config if %$pandoc_config;
  
  # 保留格式配置供 Quarto 模块使用
  # 注意: 格式配置由 Quarto.pm 直接从文件读取
  
  # Convert hyphenated keys to underscored keys recursively
  return _convert_keys($fexport_defaults);
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

  # 如果未指定配置文件，尝试默认位置
  unless ( defined $file ) {
    my $home = $ENV{HOME};

    # 如果 HOME 未定义，跳过默认配置文件搜索
    unless ( defined $home && length $home ) {
      warn "[Warn] \$HOME is not set, skipping default config file search\n";
      return {};
    }

    # XDG 规范: $XDG_CONFIG_HOME/fexport/config.yaml
    my $xdg_config_home = $ENV{XDG_CONFIG_HOME} // "$home/.config";
    my $xdg_config      = path($xdg_config_home)->child( 'fexport', 'config.yaml' );

    # 向后兼容: ~/.fexport.yaml
    my $legacy_config = path($home)->child('.fexport.yaml');

    # 优先使用 XDG 配置，其次使用 legacy 配置
    if ( $xdg_config->is_file ) {
      $file = $xdg_config->stringify;
    }
    elsif ( $legacy_config->is_file ) {
      $file = $legacy_config->stringify;
    }
    else {
      return {};    # 无默认配置文件
    }
  }

  # 增加 -f 判断确保是文件
  return {} unless -f $file;

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

  # 用户显式指定了工作目录
  if ( $opts->{workdir} ) {
    $work_dir = $cwd->child( $opts->{workdir} );
  }

  # 输入文件是绝对路径 -> 使用文件所在目录
  elsif ( defined $infile_raw && path($infile_raw)->is_absolute ) {
    $work_dir = $infile_abs->parent;
  }

  # 输入文件是相对路径或未指定 -> 使用当前目录
  else {
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

  # Ensure output directory exists
  my $out_dir_path = $abs_outfile->parent;
  unless ( $out_dir_path->exists ) {
    eval { $out_dir_path->mkpath };
    if ($@) {
      warn "[Error] Failed to create output directory '$out_dir_path': $@\n";
      exit 1;
    }
  }

  # 5. 返回相对于 work_dir 的路径 (因为脚本后续会 chdir 到 work_dir)
  my $rel_outfile = $abs_outfile->relative($work_dir);

  # 返回字符串路径 (显式 stringify 避免对象泄露给不识别 Path::Tiny 的旧代码)
  return ( "$work_dir", "$resolved_infile", "$rel_outfile" );
}

sub _recursive_merge {
  my ( $left, $right ) = @_;

  # 1. 快速返回：如果左边没定义，直接用右边；如果右边没定义，保持左边。
  return $right unless defined $left;
  return $left  unless defined $right;

  # 2. 引用相同优化：如果是同一个对象，直接返回
  return $left if $left eq $right;

  # 3. 只有双方都是 HASH 时才递归
  if ( ref($left) eq 'HASH' && ref($right) eq 'HASH' ) {

    # 浅拷贝左边作为基础，避免修改原始的 Defaults
    my %merged = %$left;

    # 遍历右边进行覆盖或深度合并
    while ( my ( $key, $r_val ) = each %$right ) {

      # 关键优化：直接传入 $merged{$key}，省去了 exists 判断
      # 如果 $merged{$key} 不存在，它是 undef，下一层递归会直接返回 $r_val
      $merged{$key} = _recursive_merge( $merged{$key}, $r_val );
    }
    return \%merged;
  }

  # 4. 其他类型（Array, Scalar）或类型不匹配时，右边覆盖左边
  return $right;
}

1;

