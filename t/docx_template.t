#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use open qw(:std :utf8);

use Archive::Zip qw(:ERROR_CODES);
use Path::Tiny;
use Test::More;
use XML::LibXML;
use YAML::XS qw(LoadFile);

use Fexport::Config qw(get_format_config merge_config);
use Fexport::Pandoc qw(build_cmd);

my $W_NS         = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
my $docx_config  = get_format_config('docx');
my $template     = path( $docx_config->{'reference-doc'} );
my $template_dir = $template->parent;

is( $template->basename, 'fexport-default.docx', 'DOCX 默认模板指向 fexport-default.docx' );
ok( $template->is_file,                                            '新默认模板存在' );
ok( $template_dir->child('economic-research-china.docx')->is_file, '旧经济研究模板仍保留' );
ok( $template_dir->child('custom-reference.docx')->is_file,        '旧通用模板仍保留' );
ok( $template_dir->child('build-fexport-default.pl')->is_file,     '可复现生成脚本随模板提供' );

my $csl = path( $docx_config->{csl} );
is( $csl->basename, 'chicago-notes-bibliography.csl', 'DOCX 使用 Chicago notes CSL' );
ok( $csl->is_file, 'Chicago CSL 文件存在' );
like( $csl->slurp_utf8, qr/<style[^>]*class="note"/, 'CSL 确认为页下注类型' );
ok( $docx_config->{metadata}{'suppress-bibliography'}, '默认抑制文末参考文献表' );
ok( !$docx_config->{metadata}{'link-citations'},       'DOCX 保持禁用引文链接' );

subtest 'build_cmd 保留 Pandoc defaults 键形' => sub {
  my $merged = merge_config( {}, { to => 'docx' } );
  my @cmd    = build_cmd(
    $merged->{pandoc},
    {
      from        => 'md',
      format_opts => $merged->{format_opts},
    },
  );
  my ($defaults_index) = grep { $cmd[$_] eq '--defaults' } 0 .. $#cmd;
  ok( defined $defaults_index, '生成临时 defaults YAML' );
  my $defaults_path = $cmd[ $defaults_index + 1 ];
  my $raw           = path($defaults_path)->slurp_utf8;
  my $defaults      = LoadFile($defaults_path);

  is( $defaults->{'reference-doc'}, $template->stringify, 'defaults 保留 reference-doc' );
  is( $defaults->{csl},             $csl->stringify,      'csl 位于 defaults 顶层' );
  like( $raw, qr/^csl:/m, 'csl 未错误移入 metadata' );
  ok( $defaults->{metadata}{'suppress-bibliography'},       'metadata 保留 suppress-bibliography' );
  ok( !exists $defaults->{metadata}{suppress_bibliography}, 'suppress-bibliography 未转成下划线键' );
  unlike( $raw, qr/^citeproc:/m, 'citeproc 仍由命令行控制' );
  ok( scalar( grep { $_ eq '--citeproc' } @cmd ), '命令行仍启用 citeproc' );
};

my $zip = Archive::Zip->new();
is( $zip->read( $template->stringify ), AZ_OK, '模板可作为 ZIP 读取' );

sub parse_member {
  my ( $zip, $name ) = @_;
  my $member = $zip->memberNamed($name);
  ok( defined $member, "$name 存在" );
  my $doc = eval { XML::LibXML->load_xml( string => scalar $member->contents(), no_network => 1 ) };
  ok( defined $doc, "$name 是有效 XML" ) or diag $@;
  return $doc;
}

sub xpath_context {
  my ($doc) = @_;
  my $xpc = XML::LibXML::XPathContext->new($doc);
  $xpc->registerNs( 'w', $W_NS );
  return $xpc;
}

sub xpath_count {
  my ( $xpc, $expression, $context ) = @_;
  my @nodes = defined $context ? $xpc->findnodes( $expression, $context ) : $xpc->findnodes($expression);
  return scalar @nodes;
}

sub style_by_id {
  my ( $xpc, $style_id ) = @_;
  my ($style) = $xpc->findnodes( '//w:style[@w:styleId="' . $style_id . '"]' );
  return $style;
}

my $styles_doc     = parse_member( $zip, 'word/styles.xml' );
my $document_doc   = parse_member( $zip, 'word/document.xml' );
my $font_table_doc = parse_member( $zip, 'word/fontTable.xml' );
my $styles         = xpath_context($styles_doc);
my $document       = xpath_context($document_doc);
my $font_table     = xpath_context($font_table_doc);

my %sizes = (
  Normal       => 24,
  BodyText     => 24,
  BodyTextChar => 24,
  Title        => 36,
  Subtitle     => 32,
  Heading1     => 32,
  Heading2     => 28,
  Heading3     => 24,
  Heading4     => 24,
  FootnoteText => 18,
  FigureNote   => 18,
  TableNote    => 18,
);

for my $style_id ( sort keys %sizes ) {
  my $style = style_by_id( $styles, $style_id );
  ok( defined $style, "$style_id 样式存在" );
  is( $styles->findvalue( 'w:rPr/w:sz/@w:val',   $style ), $sizes{$style_id}, "$style_id 的 w:sz 正确" );
  is( $styles->findvalue( 'w:rPr/w:szCs/@w:val', $style ), $sizes{$style_id}, "$style_id 的 w:szCs 同步" );
}

my $normal = style_by_id( $styles, 'Normal' );
is( $styles->findvalue( 'w:rPr/w:rFonts/@w:ascii', $normal ),    'Times New Roman', '西文正文使用 Times New Roman' );
is( $styles->findvalue( 'w:rPr/w:rFonts/@w:eastAsia', $normal ), '方正聚珍新仿简体',        '中文正文使用方正聚珍新仿简体' );
is( $styles->findvalue('//w:docDefaults/w:rPrDefault/w:rPr/w:rFonts/@w:eastAsia'),        '方正聚珍新仿简体', '文档默认中文字体已同步', );
is( xpath_count( $styles, '//w:rFonts[@w:eastAsia="SimSun" or @w:eastAsia="FangSong"]' ), 0,          '正文旧中文字体引用已清除' );
is( xpath_count( $styles, '//w:rFonts[@w:eastAsiaTheme or @w:asciiTheme or @w:hAnsiTheme or @w:cstheme]' ),
  0, '冲突主题字体覆盖已清除' );

for my $style_id (qw(Hyperlink FootnoteReference)) {
  my $style = style_by_id( $styles, $style_id );
  is( $styles->findvalue( 'w:basedOn/@w:val', $style ), 'DefaultParagraphFont',        "$style_id 基于默认字符样式" );
  is( xpath_count( $styles, 'w:rPr/w:rFonts | w:rPr/w:sz | w:rPr/w:szCs', $style ), 0, "$style_id 不含字体字号覆盖" );
}
my $hyperlink = style_by_id( $styles, 'Hyperlink' );
is( xpath_count( $styles, 'w:rPr/w:color', $hyperlink ), 1, 'Hyperlink 保留颜色' );
is( xpath_count( $styles, 'w:rPr/w:u',     $hyperlink ), 1, 'Hyperlink 保留下划线' );
my $footnote_reference = style_by_id( $styles, 'FootnoteReference' );
is( $styles->findvalue( 'w:rPr/w:vertAlign/@w:val', $footnote_reference ), 'superscript', 'Footnote Reference 保留上标', );

for my $style_id (qw(FootnoteText Heading2)) {
  my $style = style_by_id( $styles, $style_id );
  is( $styles->findvalue( 'w:pPr/w:ind/@w:firstLineChars', $style ), 0, "$style_id 显式取消字符首行缩进" );
  is( $styles->findvalue( 'w:pPr/w:ind/@w:firstLine',      $style ), 0, "$style_id 显式取消固定首行缩进" );
}
my $first_paragraph = style_by_id( $styles, 'FirstParagraph' );
is( $styles->findvalue( 'w:pPr/w:ind/@w:firstLineChars', $first_paragraph ),     200, 'First Paragraph 首行缩进两字符' );
is( xpath_count( $styles, 'w:pPr/w:ind[@w:firstLine]', $first_paragraph ),       0,   'First Paragraph 不含固定首行缩进' );
is( xpath_count( $styles, '//w:ind[@w:firstLineChars="200" and @w:firstLine]' ), 0,   '两字符缩进不再与固定值冲突' );

is( $styles->findvalue( 'w:pPr/w:spacing/@w:after',    $normal ), 120,    '正文段后间距为 6 pt' );
is( $styles->findvalue( 'w:pPr/w:spacing/@w:line',     $normal ), 312,    '正文使用 1.3 倍行距' );
is( $styles->findvalue( 'w:pPr/w:spacing/@w:lineRule', $normal ), 'auto', '正文行距规则正确' );

my $footnote_text = style_by_id( $styles, 'FootnoteText' );
is( $styles->findvalue( 'w:pPr/w:jc/@w:val',           $footnote_text ), 'left', 'Footnote Text 使用左对齐' );
is( $styles->findvalue( 'w:pPr/w:spacing/@w:after',    $footnote_text ), 60,     'Footnote Text 段后间距为 3 pt' );
is( $styles->findvalue( 'w:pPr/w:spacing/@w:line',     $footnote_text ), 240,    'Footnote Text 使用单倍行距' );
is( $styles->findvalue( 'w:pPr/w:spacing/@w:lineRule', $footnote_text ), 'auto', 'Footnote Text 行距规则正确' );

is( $document->findvalue('//w:sectPr/w:pgSz/@w:w'),                      11906,                          '页面宽度为 A4' );
is( $document->findvalue('//w:sectPr/w:pgSz/@w:h'),                      16838,                          '页面高度为 A4' );
is( $document->findvalue('//w:sectPr/w:pgMar/@w:top'),                   1440,                           '保留原页边距' );
is( $document->findvalue('//w:sectPr/w:pgMar/@w:header'),                720,                            '保留原页眉距离' );
is( $document->findvalue('//w:sectPr/w:pgMar/@w:footer'),                720,                            '保留原页脚距离' );
is( $document->findvalue('//w:sectPr/w:footnotePr/w:numFmt/@w:val'),     'decimalEnclosedCircleChinese', '脚注保留带圈数字', );
is( $document->findvalue('//w:sectPr/w:footnotePr/w:numRestart/@w:val'), 'eachPage',                     '脚注保留每页重新编号' );

my $reference_title = style_by_id( $styles, 'ReferenceTitle' );
is( $styles->findvalue( 'w:basedOn/@w:val', $reference_title ),          'Heading1', 'Reference Title 继承标题样式' );
is( xpath_count( $styles, 'w:rPr/w:sz[@w:val="15"]', $reference_title ), 0,          'Reference Title 不再使用 7.5 pt' );
my $reference = style_by_id( $styles, 'Reference' );
is( $styles->findvalue( 'w:basedOn/@w:val', $reference ), 'BodyText', 'Reference 不再继承 Reference Title' );
for my $style_id (qw(Bibliography SourceCode FootnoteBlockText)) {
  is( xpath_count( $styles, '//w:style[@w:styleId="' . $style_id . '"]' ), 1, "$style_id 标准样式已补齐" );
}
for my $style_id (qw(Abstract BlockText Compact TableCaption ImageCaption)) {
  is( xpath_count( $styles, '//w:style[@w:styleId="' . $style_id . '"]' ), 1, "$style_id 原样式保留且无重复" );
}

my %custom_styles = (
  AuthorAffiliation => [ 'paragraph', 'Author' ],
  Keywords          => [ 'paragraph', 'Abstract' ],
  SourceNote        => [ 'paragraph', 'Normal' ],
  FigureNote        => [ 'paragraph', 'SourceNote' ],
  TableNote         => [ 'paragraph', 'SourceNote' ],
  EmphasisDot       => [ 'character', 'DefaultParagraphFont' ],
);
for my $style_id ( sort keys %custom_styles ) {
  my $style = style_by_id( $styles, $style_id );
  ok( defined $style, "$style_id 自定义样式存在" );
  is( $styles->findvalue( '@w:type',          $style ), $custom_styles{$style_id}[0], "$style_id 类型正确" );
  is( $styles->findvalue( 'w:basedOn/@w:val', $style ), $custom_styles{$style_id}[1], "$style_id 继承正确" );
}
my $source_note = style_by_id( $styles, 'SourceNote' );
is( $styles->findvalue( 'w:rPr/w:sz/@w:val',       $source_note ), 18,  'Source Note 使用 9 pt' );
is( $styles->findvalue( 'w:pPr/w:spacing/@w:line', $source_note ), 240, 'Source Note 使用单倍行距' );
for my $style_id (qw(FigureNote TableNote)) {
  my $note_style = style_by_id( $styles, $style_id );
  is( $styles->findvalue( 'w:name/@w:val',       $note_style ), $style_id, "$style_id 名称与 custom-style 调用一致" );
  is( $styles->findvalue( 'w:rPr/w:sz/@w:val',   $note_style ), 18,        "$style_id 使用 9 pt" );
  is( $styles->findvalue( 'w:rPr/w:szCs/@w:val', $note_style ), 18,        "$style_id 复杂文字字号同步为 9 pt" );
}
my $emphasis_dot = style_by_id( $styles, 'EmphasisDot' );
is( $styles->findvalue( 'w:rPr/w:em/@w:val', $emphasis_dot ), 'dot',                        'Emphasis Dot 使用中文着重号' );
is( xpath_count( $styles, 'w:rPr/w:rFonts | w:rPr/w:sz | w:rPr/w:szCs', $emphasis_dot ), 0, 'Emphasis Dot 不覆盖字体字号' );

is(
  $font_table->findvalue('//w:font[@w:name="方正聚珍新仿简体"]/w:altName/@w:val'),
  'FZJuZhenXinFangS-R-GB', 'fontTable 登记中文字体别名',
);
is( xpath_count( $font_table, '//w:font[@w:name="方正聚珍新仿简体"]/*[starts-with(local-name(), "embed")]' ), 0, '中文字体未嵌入模板', );
for my $font_name ( 'Noto Serif', 'Serif', 'Monospace' ) {
  is(
    xpath_count( $font_table, '//w:font[@w:name="' . $font_name . '"]/w:altName[@w:val="Calibri"]' ),
    0, "$font_name 不再错误映射到 Calibri",
  );
}

done_testing();
