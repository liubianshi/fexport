#!/usr/bin/env perl
use strict;
use warnings;
use v5.20;
use utf8;

use Archive::Zip qw(:ERROR_CODES);
use File::Spec;
use FindBin;
use XML::LibXML;

my $W_NS           = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
my $CJK_FONT       = '方正聚珍新仿简体';
my $CJK_FONT_ALIAS = 'FZJuZhenXinFangS-R-GB';
my $WESTERN_FONT   = 'Times New Roman';

my @STYLE_ORDER = qw(
  name basedOn next link autoRedefine hidden uiPriority semiHidden unhideWhenUsed qFormat locked
  personal personalCompose personalReply rsid pPr rPr tblPr trPr tcPr tblStylePr
);
my @PPR_ORDER = qw(
  pStyle keepNext keepLines pageBreakBefore framePr widowControl numPr suppressLineNumbers pBdr shd tabs
  suppressAutoHyphens kinsoku wordWrap overflowPunct topLinePunct autoSpaceDE autoSpaceDN bidi adjustRightInd
  snapToGrid spacing ind contextualSpacing mirrorIndents suppressOverlap jc textDirection textAlignment
  textboxTightWrap outlineLvl divId cnfStyle rPr sectPr pPrChange
);
my @RPR_ORDER = qw(
  rStyle rFonts b bCs i iCs caps smallCaps strike dstrike outline shadow emboss imprint noProof snapToGrid
  vanish webHidden color spacing w kern position sz szCs highlight u effect bdr shd fitText vertAlign rtl cs em
  lang eastAsianLayout specVanish oMath rPrChange
);
my @FONT_ORDER = qw(altName panose1 charset family notTrueType pitch sig embedRegular embedBold embedItalic
  embedBoldItalic);

sub xpath_context {
  my ($doc) = @_;
  my $xpc = XML::LibXML::XPathContext->new($doc);
  $xpc->registerNs( 'w', $W_NS );
  return $xpc;
}

sub set_w_attr {
  my ( $node, $name, $value ) = @_;
  $node->setAttributeNS( $W_NS, "w:$name", $value );
  return;
}

sub direct_child {
  my ( $parent, $name ) = @_;
  for my $child ( $parent->childNodes() ) {
    next unless $child->nodeType == 1;
    return $child if $child->namespaceURI eq $W_NS && $child->localname eq $name;
  }
  return;
}

sub ordered_child {
  my ( $doc, $parent, $name, $order ) = @_;
  if ( my $child = direct_child( $parent, $name ) ) {
    return $child;
  }

  my %rank = map { $order->[$_] => $_ } 0 .. $#$order;
  die "Unknown OOXML child order for w:$name\n" unless exists $rank{$name};

  my $child = $doc->createElementNS( $W_NS, "w:$name" );
  my ($reference) = grep {
         $_->nodeType == 1
      && $_->namespaceURI eq $W_NS
      && exists $rank{ $_->localname }
      && $rank{ $_->localname } > $rank{$name}
  } $parent->childNodes();

  if ($reference) {
    $parent->insertBefore( $child, $reference );
  }
  else {
    $parent->appendChild($child);
  }
  return $child;
}

sub remove_children {
  my ( $parent, @names ) = @_;
  my %remove = map { $_ => 1 } @names;
  for my $child ( $parent->childNodes() ) {
    next unless $child->nodeType == 1;
    $parent->removeChild($child)
      if $child->namespaceURI eq $W_NS && $remove{ $child->localname };
  }
  return;
}

sub style_by_id {
  my ( $xpc, $style_id ) = @_;
  my @styles = $xpc->findnodes( '//w:style[@w:styleId="' . $style_id . '"]' );
  die "Expected exactly one style $style_id, found " . scalar(@styles) . "\n" unless @styles == 1;
  return $styles[0];
}

sub set_based_on {
  my ( $doc, $style, $based_on ) = @_;
  my $node = ordered_child( $doc, $style, 'basedOn', \@STYLE_ORDER );
  set_w_attr( $node, 'val', $based_on );
  return;
}

sub set_size {
  my ( $doc, $style, $half_points ) = @_;
  my $rpr = ordered_child( $doc, $style, 'rPr', \@STYLE_ORDER );
  for my $name (qw(sz szCs)) {
    my $node = ordered_child( $doc, $rpr, $name, \@RPR_ORDER );
    set_w_attr( $node, 'val', $half_points );
  }
  return;
}

sub set_indentation {
  my ( $doc, $style, %attrs ) = @_;
  my $ppr = ordered_child( $doc, $style, 'pPr', \@STYLE_ORDER );
  my $ind = ordered_child( $doc, $ppr,   'ind', \@PPR_ORDER );
  set_w_attr( $ind, $_, $attrs{$_} ) for sort keys %attrs;
  return $ind;
}

sub set_spacing {
  my ( $doc, $style, %attrs ) = @_;
  my $ppr     = ordered_child( $doc, $style, 'pPr',     \@STYLE_ORDER );
  my $spacing = ordered_child( $doc, $ppr,   'spacing', \@PPR_ORDER );
  set_w_attr( $spacing, $_, $attrs{$_} ) for sort keys %attrs;
  return $spacing;
}

sub add_style {
  my ( $doc, $xpc, %args ) = @_;
  my $style_id = $args{id};
  my @existing = $xpc->findnodes( '//w:style[@w:styleId="' . $style_id . '"]' );
  die "Style $style_id already exists\n" if @existing;

  my $style = $doc->createElementNS( $W_NS, 'w:style' );
  set_w_attr( $style, 'type',        $args{type} // 'paragraph' );
  set_w_attr( $style, 'customStyle', 1 );
  set_w_attr( $style, 'styleId',     $style_id );

  for my $field (qw(name basedOn next)) {
    next unless defined $args{$field};
    my $node = ordered_child( $doc, $style, $field, \@STYLE_ORDER );
    set_w_attr( $node, 'val', $args{$field} );
  }
  ordered_child( $doc, $style, 'qFormat', \@STYLE_ORDER );
  $doc->documentElement->appendChild($style);
  return $style;
}

sub clean_fonts {
  my ($xpc) = @_;

  my ($default_fonts) = $xpc->findnodes('//w:docDefaults/w:rPrDefault/w:rPr/w:rFonts');
  die "Missing document default fonts\n" unless $default_fonts;
  set_w_attr( $default_fonts, 'ascii',    $WESTERN_FONT );
  set_w_attr( $default_fonts, 'eastAsia', $CJK_FONT );
  set_w_attr( $default_fonts, 'hAnsi',    $WESTERN_FONT );
  set_w_attr( $default_fonts, 'cs',       $WESTERN_FONT );

  for my $fonts ( $xpc->findnodes('//w:rFonts') ) {
    $fonts->removeAttribute("w:$_") for qw(asciiTheme eastAsiaTheme hAnsiTheme cstheme);

    for my $attr (qw(ascii eastAsia hAnsi cs)) {
      my $value = $fonts->getAttribute("w:$attr") // '';
      set_w_attr( $fonts, $attr, $CJK_FONT )     if $value eq 'SimSun' || $value eq 'FangSong';
      set_w_attr( $fonts, $attr, $WESTERN_FONT ) if $attr ne 'eastAsia' && $value eq 'Noto Serif';
    }

    $fonts->parentNode->removeChild($fonts) unless $fonts->hasAttributes();
  }

  return;
}

sub update_styles {
  my ($doc) = @_;
  my $xpc = xpath_context($doc);

  clean_fonts($xpc);

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
  );
  set_size( $doc, style_by_id( $xpc, $_ ), $sizes{$_} ) for sort keys %sizes;

  for my $style_id (qw(Hyperlink FootnoteReference)) {
    my $style = style_by_id( $xpc, $style_id );
    set_based_on( $doc, $style, 'DefaultParagraphFont' );
    my $rpr = direct_child( $style, 'rPr' );
    remove_children( $rpr, qw(rFonts sz szCs) ) if $rpr;
  }

  for my $ind ( $xpc->findnodes('//w:ind[@w:firstLineChars="200"]') ) {
    $ind->removeAttribute('w:firstLine');
  }
  set_indentation( $doc, style_by_id( $xpc, $_ ), firstLineChars => 0, firstLine => 0 )
    for qw(FootnoteText Heading2);
  my $first_paragraph_ind = set_indentation( $doc, style_by_id( $xpc, 'FirstParagraph' ), firstLineChars => 200, );
  $first_paragraph_ind->removeAttribute('w:firstLine');

  my $normal = style_by_id( $xpc, 'Normal' );
  set_spacing( $doc, $normal, after => 120, line => 312, lineRule => 'auto' );

  my $footnote = style_by_id( $xpc, 'FootnoteText' );
  set_spacing( $doc, $footnote, after => 60, line => 240, lineRule => 'auto' );
  my $footnote_ppr = ordered_child( $doc, $footnote,     'pPr', \@STYLE_ORDER );
  my $footnote_jc  = ordered_child( $doc, $footnote_ppr, 'jc',  \@PPR_ORDER );
  set_w_attr( $footnote_jc, 'val', 'left' );

  my $reference_title = style_by_id( $xpc, 'ReferenceTitle' );
  set_based_on( $doc, $reference_title, 'Heading1' );
  if ( my $rpr = direct_child( $reference_title, 'rPr' ) ) {
    remove_children( $rpr, qw(sz szCs) );
  }

  my $reference = style_by_id( $xpc, 'Reference' );
  set_based_on( $doc, $reference, 'BodyText' );
  remove_children( $reference, 'rPr' );
  set_indentation( $doc, $reference, firstLineChars => 0, firstLine => 0 );

  my $bibliography = add_style(
    $doc, $xpc,
    id      => 'Bibliography',
    name    => 'Bibliography',
    basedOn => 'Normal',
    next    => 'Bibliography',
  );
  ordered_child( $doc, $bibliography, 'pPr', \@STYLE_ORDER );
  ordered_child( $doc, $bibliography, 'rPr', \@STYLE_ORDER );

  my $source_code = add_style(
    $doc, $xpc,
    id      => 'SourceCode',
    name    => 'Source Code',
    basedOn => 'BodyText',
    next    => 'SourceCode',
  );
  set_spacing( $doc, $source_code, line => 240, lineRule => 'auto' );
  set_indentation( $doc, $source_code, firstLineChars => 0, firstLine => 0 );
  my $source_rpr   = ordered_child( $doc, $source_code, 'rPr',    \@STYLE_ORDER );
  my $source_fonts = ordered_child( $doc, $source_rpr,  'rFonts', \@RPR_ORDER );
  set_w_attr( $source_fonts, 'ascii',    'Consolas' );
  set_w_attr( $source_fonts, 'eastAsia', 'DengXian' );
  set_w_attr( $source_fonts, 'hAnsi',    'Consolas' );
  set_w_attr( $source_fonts, 'cs',       'Monospace' );
  set_size( $doc, $source_code, 20 );

  my $footnote_block = add_style(
    $doc, $xpc,
    id      => 'FootnoteBlockText',
    name    => 'Footnote Block Text',
    basedOn => 'FootnoteText',
    next    => 'FootnoteText',
  );
  my $priority = ordered_child( $doc, $footnote_block, 'uiPriority', \@STYLE_ORDER );
  set_w_attr( $priority, 'val', 9 );
  ordered_child( $doc, $footnote_block, 'unhideWhenUsed', \@STYLE_ORDER );
  set_spacing( $doc, $footnote_block, before => 100, after => 100 );
  set_indentation( $doc, $footnote_block, firstLineChars => 0, firstLine => 0, left => 480, right => 480 );

  my $affiliation = add_style(
    $doc, $xpc,
    id      => 'AuthorAffiliation',
    name    => 'Author Affiliation',
    basedOn => 'Author',
    next    => 'BodyText',
  );
  set_indentation( $doc, $affiliation, firstLineChars => 0, firstLine => 0 );
  my $affiliation_ppr = ordered_child( $doc, $affiliation,     'pPr', \@STYLE_ORDER );
  my $affiliation_jc  = ordered_child( $doc, $affiliation_ppr, 'jc',  \@PPR_ORDER );
  set_w_attr( $affiliation_jc, 'val', 'center' );

  my $keywords = add_style(
    $doc, $xpc,
    id      => 'Keywords',
    name    => 'Keywords',
    basedOn => 'Abstract',
    next    => 'BodyText',
  );
  set_indentation( $doc, $keywords, firstLineChars => 0, firstLine => 0 );

  my $source_note = add_style(
    $doc, $xpc,
    id      => 'SourceNote',
    name    => 'Source Note',
    basedOn => 'Normal',
    next    => 'BodyText',
  );
  set_spacing( $doc, $source_note, line => 240, lineRule => 'auto' );
  set_indentation( $doc, $source_note, firstLineChars => 0, firstLine => 0 );
  set_size( $doc, $source_note, 18 );

  for my $style_id (qw(FigureNote TableNote)) {
    my $note_style = add_style(
      $doc, $xpc,
      id      => $style_id,
      name    => $style_id,
      basedOn => 'SourceNote',
      next    => 'BodyText',
    );
    set_size( $doc, $note_style, 18 );
  }

  my $emphasis = add_style(
    $doc, $xpc,
    id      => 'EmphasisDot',
    type    => 'character',
    name    => 'Emphasis Dot',
    basedOn => 'DefaultParagraphFont',
  );
  my $emphasis_rpr  = ordered_child( $doc, $emphasis,     'rPr', \@STYLE_ORDER );
  my $emphasis_mark = ordered_child( $doc, $emphasis_rpr, 'em',  \@RPR_ORDER );
  set_w_attr( $emphasis_mark, 'val', 'dot' );
  return;
}

sub update_document {
  my ($doc)      = @_;
  my $xpc        = xpath_context($doc);
  my @page_sizes = $xpc->findnodes('//w:sectPr/w:pgSz');
  die "No page size found in document.xml\n" unless @page_sizes;
  for my $page_size (@page_sizes) {
    set_w_attr( $page_size, 'w', 11906 );
    set_w_attr( $page_size, 'h', 16838 );
  }
  return;
}

sub update_font_table {
  my ($doc) = @_;
  my $xpc = xpath_context($doc);

  for my $font_name ( 'Noto Serif', 'Serif', 'Monospace' ) {
    for my $font ( $xpc->findnodes( '//w:font[@w:name="' . $font_name . '"]' ) ) {
      for my $alt_name ( $xpc->findnodes( 'w:altName[@w:val="Calibri"]', $font ) ) {
        $font->removeChild($alt_name);
      }
    }
  }

  my @existing = $xpc->findnodes( '//w:font[@w:name="' . $CJK_FONT . '"]' );
  die "Duplicate font entry for $CJK_FONT\n" if @existing > 1;
  return                                     if @existing == 1;

  my $font = $doc->createElementNS( $W_NS, 'w:font' );
  set_w_attr( $font, 'name', $CJK_FONT );
  for my $child_spec ( [ altName => $CJK_FONT_ALIAS ], [ charset => '86' ], [ family => 'roman' ],
    [ pitch => 'variable' ], )
  {
    my ( $name, $value ) = @$child_spec;
    my $child = ordered_child( $doc, $font, $name, \@FONT_ORDER );
    set_w_attr( $child, 'val', $value );
  }
  $doc->documentElement->appendChild($font);
  return;
}

my $input_default  = File::Spec->catfile( $FindBin::RealBin, 'economic-research-china.docx' );
my $output_default = File::Spec->catfile( $FindBin::RealBin, 'fexport-default.docx' );
die "Usage: perl $0 [input.docx [output.docx]]\n" if @ARGV > 2;
my $input  = $ARGV[0] // $input_default;
my $output = $ARGV[1] // $output_default;

my $zip = Archive::Zip->new();
$zip->read($input) == AZ_OK or die "Failed to read $input\n";

my %updates = (
  'word/styles.xml'    => \&update_styles,
  'word/document.xml'  => \&update_document,
  'word/fontTable.xml' => \&update_font_table,
);

for my $member_name ( sort keys %updates ) {
  my $member = $zip->memberNamed($member_name) or die "Missing DOCX member $member_name\n";
  my $doc    = XML::LibXML->load_xml( string => scalar $member->contents(), no_network => 1 );
  $updates{$member_name}->($doc);
  $member->contents( $doc->toString(0) );
}

$zip->writeToFileNamed($output) == AZ_OK or die "Failed to write $output\n";
print "Created $output\n";
