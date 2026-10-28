#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP;
use Path::Tiny;

# 加载 Quarto 模块——它会设置 $YAML::XS::Boolean = "JSON::PP"，
# 这正是我们要验证的行为，所以必须在使用 YAML::XS 之前 use 它。
use Fexport::Quarto;
use YAML::XS qw(Dump DumpFile LoadFile);

# 回归测试：写入 quarto 的 _metadata.yml 时，布尔值必须序列化为 YAML 裸词
# true/false，而不是 Perl 私有标签。
#
# 背景：Fexport::Defaults 用 JSON::PP::true / JSON::PP::false 作为布尔默认值。
# 若用纯 YAML.pm 的 DumpFile，会写成
#   link-citations: !!perl/scalar:JSON::PP::Boolean 0
# 导致 quarto 报 YAMLException: unknown tag ...perl/scalar:JSON::PP::Boolean。
# Quarto.pm 改用与全仓一致的 YAML::XS 并设置 $YAML::XS::Boolean="JSON::PP"，
# JSON::PP::Boolean 便原生序列化为裸词布尔，无需手工消毒。

is( $YAML::XS::Boolean, 'JSON::PP', 'Fexport::Quarto 设置了 $YAML::XS::Boolean = "JSON::PP"' );

subtest 'JSON::PP 布尔序列化为裸词 true/false，不含 Perl 标签' => sub {
  my $meta = {
    "link-citations" => JSON::PP::false,
    citeproc         => JSON::PP::true,
    nested           => { toc => JSON::PP::false },
  };

  my $yaml = Dump($meta);
  unlike( $yaml, qr/perl\/scalar|Boolean/, 'Dump 输出不含 Perl 私有布尔标签' );
  like( $yaml, qr/link-citations:\s*false\b/, 'link-citations 输出为裸词 false' );
  like( $yaml, qr/citeproc:\s*true\b/,        'citeproc 输出为裸词 true' );
  like( $yaml, qr/toc:\s*false\b/,            '嵌套 hash 内的布尔也是裸词' );
};

subtest '_metadata.yml 往返：布尔为裸词且 CJK 无损' => sub {
  my $tmp  = Path::Tiny->tempfile( SUFFIX => '.yml' );
  my $meta = {
    title            => '世界投资报告 2026',
    author           => '刘变石',
    lang             => 'zh',
    "link-citations" => JSON::PP::false,
  };

  DumpFile( $tmp->stringify, $meta );
  my $raw = $tmp->slurp_raw;
  unlike( $raw, qr/perl\/scalar/, '写入文件不含 Perl 私有标签' );

  my $back = LoadFile( $tmp->stringify );
  is( $back->{title},  '世界投资报告 2026', 'CJK 标题往返一致' );
  is( $back->{author}, '刘变石',         'CJK 作者往返一致' );
};

done_testing();
