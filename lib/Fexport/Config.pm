package Fexport::Config;

use v5.20;
use strict;
use warnings;
use Exporter 'import';
use YAML::XS qw(LoadFile);
use Path::Tiny;
use Storable qw(dclone);

# 全局配置 YAML::XS，确保整个应用行为一致
$YAML::XS::Unicode = 1;

our @EXPORT_OK = qw(load_config merge_config process_params get_format_config);

use Fexport::Util qw(find_resource);

use Fexport::Defaults qw(get_defaults);

# Raw format sections from defaults (populated by _load_defaults, keyed by format name)
my %FORMAT_RAW;

# Load Global Defaults from Fexport::Defaults
sub _load_defaults {
  my $raw = get_defaults();

  # 提取格式特定配置 (保持原样，通常为连字符，直接用于 Pandoc --defaults)
  %FORMAT_RAW = %{ $raw->{formats} // {} };

  # 返回全局配置并转换 key (连字符 -> 下划线，方便 Perl 内部逻辑使用)
  return _convert_keys( $raw->{global} // {} );
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

# 格式配置缓存
my %FORMAT_CONFIG_CACHE;

sub _process_format_config {
  my ($format) = @_;
  return {} unless exists $FORMAT_RAW{$format};

  my $copy = dclone( $FORMAT_RAW{$format} );

  # 将 from-extensions 数组转换为 pandoc from 字符串
  if ( my $extensions = delete $copy->{'from-extensions'} ) {
    if ( ref $extensions eq 'ARRAY' && @$extensions ) {
      $copy->{from} = 'markdown+' . join( '+', @$extensions );
    }
  }

  return $copy;
}

sub get_format_config {
  my ($format) = @_;
  _get_defaults();    # 确保 %FORMAT_RAW 已填充
  return $FORMAT_CONFIG_CACHE{$format} //= _process_format_config($format);
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
  # 注意：_get_defaults() 同时承担首次填充 %FORMAT_RAW 的副作用，必须先于 formats 合并执行
  my $merged = _get_defaults();

  if ( ref $file_config eq 'HASH' ) {

    # 浅拷贝避免污染调用方（merge_config 在语义上应只读 $file_config）
    my %local = %$file_config;

    # 1) global.* 上提，与 defaults 同层（与 _load_defaults 的解构对称）
    if ( my $g = delete $local{global} ) {
      $merged = _recursive_merge( $merged, $g ) if ref $g eq 'HASH';
    }

    # 2) formats.* 并入 %FORMAT_RAW：同名格式深合并，新增格式直接添加
    if ( my $f = delete $local{formats} ) {
      if ( ref $f eq 'HASH' ) {
        for my $fmt ( keys %$f ) {
          $FORMAT_RAW{$fmt} =
            exists $FORMAT_RAW{$fmt}
            ? _recursive_merge( $FORMAT_RAW{$fmt}, $f->{$fmt} )
            : $f->{$fmt};
        }
        %FORMAT_CONFIG_CACHE = ();    # 清缓存，避免 get_format_config 返回旧 dclone
      }
    }

    # 3) 剩余顶层键走原合并（兼容扁平 yaml: to / pandoc / outfile ...）
    $merged = _recursive_merge( $merged, \%local ) if %local;
  }

  $merged = _recursive_merge( $merged, $cli_opts ) if $cli_opts;

  # 将格式特定配置挂载到 format_opts，供 build_cmd / Quarto 使用
  if ( defined $merged->{to} ) {
    $merged->{format_opts} = get_format_config( $merged->{to} );
  }

  return $merged;
}

# markdown 家族扩展名 → 渲染器分派键。
# script/fexport 按 md / rmd / qmd 三个字符串挑渲染器，故必须先归一：
# 未归一时 .Rmd（R Markdown 的规范写法）、.markdown、.rmarkdown 会落空全部分支，
# md_lines 保持为空，pandoc 收到空 stdin 却以退出码 0 结束，静默产出空文档。
# 键集合需与 Fexport::Defaults 的 pandoc.markdown-exts 保持一致。
my %FROM_ALIAS = (
  md        => 'md',
  markdown  => 'md',
  rmd       => 'rmd',
  rmarkdown => 'rmd',
  qmd       => 'qmd',
  quarto    => 'qmd',
);

# 归一到分派键；无法识别的扩展名按 markdown 处理，但要出声，不能静默
sub _normalize_from {
  my ($from) = @_;
  return 'md' unless defined $from && length $from;

  my $key = $FROM_ALIAS{ lc $from };
  return $key if $key;

  warn "[Warn] Unknown input format '$from', treating it as markdown.\n";
  return 'md';
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
  $opts->{from} = _normalize_from( $opts->{from} );
  $opts->{to} //= "html";

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

  # 5. 返回字符串路径 (显式 stringify 避免对象泄露给不识别 Path::Tiny 的旧代码)
  # outfile 返回绝对路径：fexport 主脚本对 cwd/ARGV 做了 decode_utf8，得到带 UTF-8
  # flag 的宽字符串。若返回相对路径，下游 Path::Tiny->absolute() 会与 Cwd::getcwd()
  # 的字节串拼接，触发 byte→Latin-1 升级，最终 syscall 看到双重 UTF-8 编码而 ENOENT。
  return ( "$work_dir", "$resolved_infile", "$abs_outfile" );
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

