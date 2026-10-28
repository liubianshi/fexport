use strict;
use warnings;
use Test::More;
use Storable qw(dclone);
use JSON::PP ();

use Fexport::Util     qw(extract_yaml_frontmatter merge_frontmatter_into_defaults);
use Fexport::Defaults qw(get_defaults);
use Fexport::Config   qw(get_format_config);

my $TRUE  = JSON::PP::true;
my $FALSE = JSON::PP::false;

# ------------------------------------------------------------------------------
# 规则 1：嵌套 variables / metadata 直接深合并到对应层
# ------------------------------------------------------------------------------
{
  my $opts = { variables => { indent => $TRUE }, metadata => { author => ['甲'] } };
  my $merged =
    merge_frontmatter_into_defaults( $opts, { variables => { fontsize => '12pt' }, metadata => { title => 'T' } } );

  is( $merged->{variables}{fontsize}, '12pt', "规则 1: 嵌套 variables 合入 variables 层" );
  ok( $merged->{variables}{indent}, "规则 1: 原有 variables 保留" );
  is( $merged->{metadata}{title}, 'T', "规则 1: 嵌套 metadata 合入 metadata 层" );
}

# ------------------------------------------------------------------------------
# 规则 2 / 3：defaults 的 variables / metadata 已有该键时，白名单不得抢走它
#   toc 同时是模板变量与 pandoc defaults 顶层开关，是检验优先级的关键用例
# ------------------------------------------------------------------------------
for my $layer (qw(variables metadata)) {
  my $merged = merge_frontmatter_into_defaults( { $layer => { toc => $FALSE } }, { toc => $TRUE } );
  ok( $merged->{$layer}{toc}, "$layer 层已有 toc，仍合到该层" );
  ok( !exists $merged->{toc}, "$layer 层已有 toc，不被白名单提升到顶层" );
}

# ------------------------------------------------------------------------------
# 规则 4a：defaults 顶层已有该键 —— front matter 覆盖顶层值
# ------------------------------------------------------------------------------
{
  my $merged = merge_frontmatter_into_defaults( { citeproc => $FALSE }, { citeproc => $TRUE } );
  ok( $merged->{citeproc},         "顶层 citeproc 被 front matter 覆盖为真" );
  ok( !exists $merged->{metadata}, "不产生多余的 metadata 层" );

  my $arr =
    merge_frontmatter_into_defaults( { 'include-in-header' => ['/a.tex'] }, { 'include-in-header' => ['/b.tex'] } );
  is_deeply( $arr->{'include-in-header'}, [ '/a.tex', '/b.tex' ], "数组取并集而非替换" );
}

# ------------------------------------------------------------------------------
# 规则 4b（本次修复）：顶层未预置、但属于 pandoc defaults 开关的键，同样提升到顶层
#   回归 issue #1 的次生问题：citeproc 曾被投影进 metadata 而被 pandoc 静默忽略
# ------------------------------------------------------------------------------
{
  my $opts   = { ext => 'tex', metadata => { title => '原标题' } };
  my $merged = merge_frontmatter_into_defaults( $opts, { citeproc => $TRUE } );

  ok( $merged->{citeproc},                   "citeproc 提升到 defaults 顶层" );
  ok( !exists $merged->{metadata}{citeproc}, "citeproc 不再落进 metadata" );
  is( $merged->{metadata}{title}, '原标题', "原有 metadata 未被破坏" );
}

{
  my $merged = merge_frontmatter_into_defaults(
    {},
    {
      filters              => ['--lua-filter=x.lua'],
      'number-sections'    => $TRUE,
      'top-level-division' => 'chapter',
    }
  );

  is_deeply( $merged->{filters}, ['--lua-filter=x.lua'], "白名单: 数组值提升到顶层" );
  ok( $merged->{'number-sections'}, "白名单: 布尔值提升到顶层" );
  is( $merged->{'top-level-division'}, 'chapter', "白名单: 字符串值提升到顶层" );
  ok( !exists $merged->{metadata}, "白名单全命中时不生成 metadata 层" );
}

# ------------------------------------------------------------------------------
# 规则 5：非 pandoc defaults 键仍须兜底到 metadata
#   pandoc 遇到未知顶层键会直接报错退出，兜底不可省
# ------------------------------------------------------------------------------
{
  my $merged = merge_frontmatter_into_defaults( {}, { title => 'T', author => ['甲'], nocite => '[@*]' } );

  is( $merged->{metadata}{title}, 'T', "title 兜底到 metadata" );
  ok( !exists $merged->{title},  "title 不得进入顶层，否则 pandoc 报错" );
  ok( !exists $merged->{author}, "author 不得进入顶层" );
  is( $merged->{metadata}{nocite}, '[@*]', "nocite 兜底到 metadata" );
}

# bibliography / csl 是 pandoc 元数据字段，写在 metadata 下本就有效，维持既有落位
{
  my $merged = merge_frontmatter_into_defaults( {}, { bibliography => 'refs.json', csl => 'gb.csl' } );
  is( $merged->{metadata}{bibliography}, 'refs.json', "bibliography 维持落在 metadata" );
  is( $merged->{metadata}{csl},          'gb.csl',    "csl 维持落在 metadata" );
}

# ------------------------------------------------------------------------------
# 入参不可被修改
# ------------------------------------------------------------------------------
{
  my $opts   = { metadata => { title => '原标题' } };
  my $before = dclone($opts);
  merge_frontmatter_into_defaults( $opts, { citeproc => $TRUE, title => '新标题' } );
  is_deeply( $opts, $before, "merge 不修改入参 format_opts" );
}

# 空 front matter 原样返回
{
  my $opts = { ext => 'docx' };
  is( merge_frontmatter_into_defaults( $opts, {} ),    $opts, "空 front matter 返回原引用" );
  is( merge_frontmatter_into_defaults( $opts, undef ), $opts, "undef front matter 返回原引用" );
}

# ------------------------------------------------------------------------------
# issue #1 主问题：各终端产物格式的 citeproc 默认值必须一致
# ------------------------------------------------------------------------------
{
  my $formats = get_defaults()->{formats};

  for my $fmt (qw(docx html beamer pdf pptx)) {
    ok( $formats->{$fmt}{citeproc}, "格式 $fmt 默认启用 citeproc" );
  }

  # tex / latex 是中间产物，引文交由后续 BibTeX 处理，刻意不开
  for my $fmt (qw(tex latex)) {
    ok( !$formats->{$fmt}{citeproc}, "格式 $fmt 刻意不启用 citeproc" );
  }
}

# ------------------------------------------------------------------------------
# 端到端：docx 走完 extract + merge 后，citeproc 必须出现在 defaults 顶层
#   经 get_format_config 取 profile，与 script/fexport 实际喂给 build_cmd 的形状一致
# ------------------------------------------------------------------------------
{
  my $md = <<'MD';
---
title: Minimal citation test
bibliography: refs.json
---

Literate programming was introduced by Knuth [@knuth1984].
MD

  my $fm = extract_yaml_frontmatter($md);
  is( $fm->{bibliography}, 'refs.json', "front matter 解析出 bibliography" );

  my $merged = merge_frontmatter_into_defaults( get_format_config('docx'), $fm );
  ok( $merged->{citeproc}, "docx 合并 front matter 后顶层仍有 citeproc" );
  is( $merged->{metadata}{bibliography}, 'refs.json', "docx 的 bibliography 落在 metadata" );
}

done_testing();
