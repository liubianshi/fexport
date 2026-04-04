package Fexport::Pandoc;

use v5.20;
use strict;
use warnings;
use utf8;
use Exporter 'import';
use List::Util       qw(any);
use Text::ParseWords qw(shellwords);
use YAML::XS         qw(DumpFile);
use File::Temp       qw(tempfile);

our @EXPORT_OK = qw(build_cmd);

# 全局配置 YAML::XS，确保整个应用行为一致
$YAML::XS::Boolean = "JSON::PP";

# fexport 内部 key，不传给 pandoc
my %FEXPORT_ONLY = map { $_ => 1 } qw(ext intermediate intermediate_ext from-extensions from);

sub build_cmd {
  my ( $config, $params ) = @_;

  # 1. 确定输入格式
  my $from      = $params->{from} // 'md';
  my $input_fmt = $from;

  if ( my $fmt_from = $params->{format_opts}{from} ) {
    $input_fmt = $fmt_from if index( $from, '+' ) == -1;
  }
  elsif ( defined $config->{markdown_exts} && any { $_ eq $from } @{ $config->{markdown_exts} } ) {
    my $fmt = $config->{markdown_fmt};
    $input_fmt = ref($fmt) eq 'ARRAY' ? join( '+', @$fmt ) : $fmt;
  }

  # 2. 解析基础命令与选项
  my @base_cmd = shellwords( $config->{cmd} // 'pandoc' );
  my @config_opts =
    ref( $config->{user_opts} ) eq 'ARRAY' ? @{ $config->{user_opts} } : shellwords( $config->{user_opts} // '' );
  my @cli_opts =
    ref( $params->{user_opts} ) eq 'ARRAY' ? @{ $params->{user_opts} } : shellwords( $params->{user_opts} // '' );

  # 3. 格式配置转临时 defaults 文件
  my $defaults_file;
  if ( my $format_opts = $params->{format_opts} ) {
    my %pandoc_defaults = map { $_ => $format_opts->{$_} } grep { !$FEXPORT_ONLY{$_} } keys %$format_opts;

    if ( keys %pandoc_defaults ) {
      ( undef, $defaults_file ) = tempfile( "fexport-defaults-XXXXXX", TMPDIR => 1, SUFFIX => '.yaml', UNLINK => 1 );

      # 直接使用 DumpFile，简单、快速、符合全局 Unicode 设置
      DumpFile( $defaults_file, \%pandoc_defaults );

      if ( $params->{verbose} ) {

        # 调试输出：直接读取文件展示，确保所见即所得
        my $content = do { local $/; open my $fh, '<:utf8', $defaults_file; <$fh> };
        warn "[Debug] Generated Pandoc Defaults ($defaults_file):\n$content\n";
      }
    }
  }

  # 4. 构建最终命令列表
  my @cmd = ( @base_cmd, '--from', $input_fmt, @{ $config->{filters} // [] } );
  push @cmd, "--defaults", $defaults_file if $defaults_file;
  push @cmd, ( @config_opts, @cli_opts );
  if ( $params->{verbose} ) {
    push @cmd, '--verbose';
    print join( "\n", @cmd ), "\n";
  }

  return @cmd;
}

1;
