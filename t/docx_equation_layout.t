#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use open qw(:std :utf8);

use Test::More;
use XML::LibXML;

use Fexport::PostProcess;

my $W_NS     = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
my $M_NS     = 'http://schemas.openxmlformats.org/officeDocument/2006/math';
my $EM_SPACE = chr(0x2001);

sub parse_document {
  my ($body) = @_;
  my $xml = <<"XML";
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="$W_NS" xmlns:m="$M_NS">
  <w:body>
    $body
    <w:sectPr>
      <w:pgSz w:w="12000" w:h="16000"/>
      <w:pgMar w:top="1000" w:right="2000" w:bottom="1000" w:left="1000"/>
    </w:sectPr>
  </w:body>
</w:document>
XML
  return XML::LibXML->load_xml( string => $xml, no_network => 1 );
}

sub xpath_context {
  my ($dom) = @_;
  my $xpc = XML::LibXML::XPathContext->new($dom);
  $xpc->registerNs( 'w', $W_NS );
  $xpc->registerNs( 'm', $M_NS );
  return $xpc;
}

sub node_count {
  my ( $xpc, $expression, $context ) = @_;
  my @nodes = defined $context ? $xpc->findnodes( $expression, $context ) : $xpc->findnodes($expression);
  return scalar @nodes;
}

subtest '编号公式移入对称三列表格' => sub {
  my $body = <<"XML";
<w:p>
  <w:pPr>
    <w:pStyle w:val="DisplayMath"/>
    <w:spacing w:after="120"/>
    <w:ind w:firstLine="200" w:firstLineChars="200"/>
    <w:jc w:val="left"/>
  </w:pPr>
  <w:bookmarkStart w:id="7" w:name="eq-test"/>
  <m:oMathPara>
    <m:oMathParaPr><m:jc m:val="center"/></m:oMathParaPr>
    <m:oMath>
      <m:r><m:t xml:space="preserve">a${EM_SPACE}b</m:t></m:r>
      <m:r><m:t xml:space="preserve">${EM_SPACE}</m:t></m:r>
      <m:r><m:rPr><m:sty m:val="p"/></m:rPr><m:t>(</m:t></m:r>
      <m:r><m:t>1.2</m:t></m:r>
      <m:r><m:rPr><m:sty m:val="p"/></m:rPr><m:t>)</m:t></m:r>
    </m:oMath>
  </m:oMathPara>
  <w:bookmarkEnd w:id="7"/>
</w:p>
XML
  my $dom = parse_document($body);
  Fexport::PostProcess::_process_docx_dom($dom);
  my $xpc = xpath_context($dom);

  is( node_count( $xpc, '/w:document/w:body/w:tbl' ),         1,       '原段落替换为一个表格' );
  is( $xpc->findvalue('//w:tbl/w:tblPr/w:tblW/@w:w'),         9000,    '表格宽度等于版心宽度' );
  is( $xpc->findvalue('//w:tbl/w:tblPr/w:tblInd/@w:w'),       0,       '表格缩进为零' );
  is( $xpc->findvalue('//w:tbl/w:tblPr/w:tblLayout/@w:type'), 'fixed', '表格使用固定布局' );
  my @grid_widths = map { $_->getAttribute('w:w') } $xpc->findnodes('//w:tbl/w:tblGrid/w:gridCol');
  is_deeply( \@grid_widths, [ 900, 7200, 900 ], '左右列等宽，中间列占剩余宽度' );
  my @cell_widths = map { $_->getAttribute('w:w') } $xpc->findnodes('//w:tbl/w:tr/w:tc/w:tcPr/w:tcW');
  is_deeply( \@cell_widths, \@grid_widths, '单元格宽度与表格网格一致' );
  my @borders = map { $_->getAttribute('w:val') } $xpc->findnodes('//w:tbl/w:tblPr/w:tblBorders/*');
  is_deeply( \@borders, [ ('nil') x 6 ], '表格及内部边框全部关闭' );
  is( node_count( $xpc, '//w:tc/w:tcPr/w:vAlign[@w:val="center"]' ), 3, '三个单元格均垂直居中' );

  my ($center_cell) = $xpc->findnodes('//w:tbl/w:tr/w:tc[2]');
  is( node_count( $xpc, './w:p/m:oMathPara/m:oMath', $center_cell ), 1, '中间列保留唯一 display-math 对象' );
  my $math_text = join '', map { $_->textContent } $xpc->findnodes( './w:p/m:oMathPara/m:oMath//m:t', $center_cell );
  is( $math_text, "a${EM_SPACE}b",                                                            '公式主体完整且内部 EM SPACE 保留' );
  is( node_count( $xpc, './w:p/w:bookmarkStart[@w:name="eq-test"]', $center_cell ), 1,        '公式书签起点保留' );
  is( node_count( $xpc, './w:p/w:bookmarkEnd[@w:id="7"]', $center_cell ),           1,        '公式书签终点保留' );
  is( $xpc->findvalue( './w:p/w:pPr/w:jc/@w:val', $center_cell ),                   'center', '公式段落居中' );
  is( $xpc->findvalue( './w:p/w:pPr/w:ind/@w:firstLine', $center_cell ),            0,        '固定首行缩进清零' );
  is( $xpc->findvalue( './w:p/w:pPr/w:ind/@w:firstLineChars', $center_cell ),       0,        '字符首行缩进清零' );
  is( $xpc->findvalue( './w:p/w:pPr/w:spacing/@w:after', $center_cell ),            0,        '公式段后间距清零' );
  my ($p_pr) = $xpc->findnodes( './w:p/w:pPr', $center_cell );
  my @p_pr_names = map { $_->localName } grep { $_->nodeType == 1 } $p_pr->childNodes;
  is_deeply( \@p_pr_names, [qw(pStyle spacing ind jc)], '段落属性保持 OOXML schema 顺序' );

  is( $xpc->findvalue('//w:tbl/w:tr/w:tc[3]/w:p/w:r/w:t'),           '(1.2)', '原编号文本移至右侧单元格' );
  is( $xpc->findvalue('//w:tbl/w:tr/w:tc[3]/w:p/w:pPr/w:jc/@w:val'), 'right', '编号段落右对齐' );
  is( node_count( $xpc, '//m:t[text()="(1.2)"]' ),                   0,       '编号不再留在数学对象中' );
  is( node_count( $xpc, '//w:t[text()="(1.2)"]' ),                   1,       '编号文本没有重复' );
  is( node_count( $xpc, '//w:tbl/w:tr/w:tc[1]//w:t' ),               0,       '左侧单元格留空' );

  my $once = $dom->toString;
  Fexport::PostProcess::_process_docx_dom($dom);
  is( $dom->toString, $once, '重复执行不会再次搬移或改写公式' );
};

subtest '无法可靠识别的公式保持原样' => sub {
  my $body = <<"XML";
<w:p>
  <w:bookmarkStart w:id="1" w:name="eq-unnumbered"/>
  <m:oMathPara><m:oMath><m:r><m:t xml:space="preserve">x${EM_SPACE}y</m:t></m:r></m:oMath></m:oMathPara>
  <w:bookmarkEnd w:id="1"/>
</w:p>
<w:p>
  <w:bookmarkStart w:id="2" w:name="eq-nonnumeric"/>
  <m:oMathPara><m:oMath><m:r><m:t>(A)</m:t></m:r></m:oMath></m:oMathPara>
  <w:bookmarkEnd w:id="2"/>
</w:p>
<w:p>
  <w:bookmarkStart w:id="3" w:name="eq-ambiguous"/>
  <m:oMathPara><m:oMath><m:r><m:t>(1)(2)</m:t></m:r></m:oMath></m:oMathPara>
  <w:bookmarkEnd w:id="3"/>
</w:p>
<w:p>
  <w:bookmarkStart w:id="4" w:name="eq-multiple"/>
  <m:oMathPara><m:oMath><m:r><m:t>x</m:t></m:r></m:oMath></m:oMathPara>
  <m:oMathPara><m:oMath><m:r><m:t>(4)</m:t></m:r></m:oMath></m:oMathPara>
  <w:bookmarkEnd w:id="4"/>
</w:p>
<w:p>
  <w:bookmarkStart w:id="6" w:name="eq-partial-run"/>
  <m:oMathPara><m:oMath><m:r><m:t>x(6)</m:t></m:r></m:oMath></m:oMathPara>
  <w:bookmarkEnd w:id="6"/>
</w:p>
<w:p>
  <w:bookmarkStart w:id="5" w:name="other-label"/>
  <m:oMathPara><m:oMath><m:r><m:t>(5)</m:t></m:r></m:oMath></m:oMathPara>
  <w:bookmarkEnd w:id="5"/>
</w:p>
XML
  my $dom    = parse_document($body);
  my $before = $dom->toString;
  Fexport::PostProcess::_process_docx_dom($dom);
  is( $dom->toString, $before, '未编号、非数字编号、多公式和非 eq 书签均不改写' );
  my $xpc = xpath_context($dom);
  is( node_count( $xpc, '//w:tbl' ), 0, '跳过情况不会生成表格' );
  is( $xpc->findvalue('//w:p[w:bookmarkStart[@w:name="eq-unnumbered"]]//m:t'),
    "x${EM_SPACE}y", '未编号公式内部 EM SPACE 保持不变' );
};

subtest '单个数学 run 中的完整编号也可识别' => sub {
  my $body = <<'XML';
<w:p>
  <w:bookmarkStart w:id="6" w:name="eq-single-run"/>
  <m:oMathPara><m:oMath>
    <m:r><m:t>x</m:t></m:r>
    <m:r><m:t>(6)</m:t></m:r>
  </m:oMath></m:oMathPara>
  <w:bookmarkEnd w:id="6"/>
</w:p>
XML
  my $dom = parse_document($body);
  Fexport::PostProcess::_process_docx_dom($dom);
  my $xpc = xpath_context($dom);
  is( $xpc->findvalue('//w:tbl/w:tr/w:tc[3]//w:t'), '(6)', '完整单 run 编号移至右列' );
  is( node_count( $xpc, '//m:oMathPara/m:oMath' ),  1,     '单 run 公式主体保留' );
};

subtest '版心宽度无效时跳过' => sub {
  my $body = <<'XML';
<w:p>
  <w:bookmarkStart w:id="8" w:name="eq-invalid-width"/>
  <m:oMathPara><m:oMath><m:r><m:t>(8)</m:t></m:r></m:oMath></m:oMathPara>
  <w:bookmarkEnd w:id="8"/>
</w:p>
XML
  my $dom = parse_document($body);
  my ($pg_sz) = $dom->findnodes('//*[local-name()="pgSz"]');
  $pg_sz->setAttribute( 'w:w', 1000 );
  my $before = $dom->toString;
  Fexport::PostProcess::_process_docx_dom($dom);
  is( $dom->toString, $before, '页宽小于左右页边距时保留原公式段落' );
};

done_testing();
