#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Archive::Zip qw(:ERROR_CODES);
use Path::Tiny;
use Test::More;
use XML::LibXML;
use Fexport::Config qw(get_format_config);

my $pandoc = `command -v pandoc 2>/dev/null`;
chomp $pandoc;
plan skip_all => 'pandoc is required for DOCX integration' unless $pandoc;

my %paragraphs = (
  TableNote => 'TableNote', FigureNote => 'FigureNote', Abstract => 'Abstract',
  Keywords => 'Keywords', Author => 'Author', AuthorAffiliation => 'Author Affiliation',
  BlockText => 'Block Text', SourceNote => 'Source Note',
  CorrespondingAuthor => 'Corresponding Author', Funding => 'Funding',
  Acknowledgements => 'Acknowledgements',
);
my $dir = Path::Tiny->tempdir;
my $input = $dir->child('styles.md');
my $output = $dir->child('styles.docx');
my $markdown = join "\n\n", map {
  qq{::: {custom-style="$paragraphs{$_}"}\nmarker-$_\n:::}
} sort keys %paragraphs;
$markdown .= qq{\n\nPlain [marker-EmphasisDot]{custom-style="Emphasis Dot"}.\n\n> marker-quote\n\nPlain body.\n};
$input->spew_utf8($markdown);
my $config = get_format_config('docx');
is(system($pandoc, '-f', 'markdown', "--reference-doc=$config->{'reference-doc'}",
  $input->stringify, '-o', $output->stringify), 0, 'Pandoc renders style fixture');
BAIL_OUT('DOCX was not generated') unless $output->is_file;
my $zip = Archive::Zip->new;
is($zip->read($output->stringify), AZ_OK, 'rendered DOCX is readable');
my $ns = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
sub context {
  my ($member) = @_;
  my $doc = XML::LibXML->load_xml(string => scalar $zip->memberNamed($member)->contents, no_network => 1);
  my $xpc = XML::LibXML::XPathContext->new($doc);
  $xpc->registerNs(w => $ns);
  return $xpc;
}
my $document = context('word/document.xml');
my $styles = context('word/styles.xml');
for my $id (sort keys %paragraphs) {
  is($document->findvalue(qq{//w:p[w:r/w:t="marker-$id"]/w:pPr/w:pStyle/\@w:val}),
    $id, "$paragraphs{$id} is applied to its paragraph");
  is($styles->findvalue(qq{//w:style[\@w:styleId="$id"]/w:name/\@w:val}),
    $paragraphs{$id}, "$id keeps the reference style name");
}
for my $id (qw(CorrespondingAuthor Funding Acknowledgements)) {
  is($styles->findvalue(qq{//w:style[\@w:styleId="$id"]/w:basedOn/\@w:val}),
    'SourceNote', "$id inherits the configured note formatting, not a generated fallback");
}
is($document->findvalue('//w:r[w:t="marker-EmphasisDot"]/w:rPr/w:rStyle/@w:val'),
  'EmphasisDot', 'character style is applied to the span');
is($document->findvalue('//w:p[w:r/w:t="marker-quote"]/w:pPr/w:pStyle/@w:val'),
  'BlockText', 'native block quotation uses Block Text');
like($document->findvalue('//w:p[w:r/w:t="Plain body."]/w:pPr/w:pStyle/@w:val'),
  qr/\A(?:BodyText|FirstParagraph)\z/, 'custom styles do not leak into following body text');
done_testing;
