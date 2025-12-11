package Fexport::PostProcess;
use strict;
use warnings;
use v5.20;
use Exporter 'import';
use File::Spec;
use File::Temp qw(tempdir);
use File::Basename qw(dirname);
use Cwd qw(getcwd);
use Fexport::Util qw(write2file);

our @EXPORT_OK = qw(
    str_adj_etal str_adj_file str_adj_html str_adj_md_contents_for_tex
    str_adj_tex str_adj_word str_adj_word_documents str_adj_word_footnotes str_group_by_paragraph
);

sub str_adj_etal {
  my $content_ref = shift or return;
  my $tag_start   = qr/ <w:r> \s* <w:t \s xml:space="preserve"> /imx;
  for ( @{$content_ref} ) {
    s{ (?<=[a-zA-Z]) (,\s|\s) 等                  }{$1et al.}mxg;
    s{ \s (等 (?: \s\( | （ | ,\s  | <\/a> | <\/w:t>)) }{$1}gx;
  }
}

sub str_adj_file {
  my ( $file, $sub ) = @_;

  open my $infh, "<", $file
    or die "Cannot open $file: $!\n";
  my @contents = <$infh>;
  chomp(@contents);
  close $infh;

  my $newcontests_ref = $sub->( \@contents );
  open my $outfh, ">", $file
    or die "Cannot open $file: $!";
  print $outfh join "", @$newcontests_ref;
  close $outfh;
}

sub str_adj_html {
  my $cjk = qr/[^A-Za-z,."'';。；，：“”（）、？《》]/;
  for ( @{ shift() } ) {
    s/([^A-Za-z,."';])\s(<span class="citation" data\-cites="[^\w])/$1$2/g;
    s/($cjk)(<span class="citation"[^>]+>(<a href=[^>]+>)?[A-Za-z])/$1 $2/g;
  }
}

sub str_adj_md_contents_for_tex {
  my $content_ref = shift;
  my $math_sign   = qr/\$\$/;
  my $eq_begin    = qr/\\begin\{equa[^\}]+\}/;
  my $eq_end      = qr/\\end\{equa[^\}]+\}/;

  for ( @{$content_ref} ) {
    s/$math_sign ($eq_begin)/$1/gx;
    s/($eq_end) [^\$]* $math_sign/$1/gx;
  }
}

sub str_adj_tex {
  my $content_ref = shift;
  my $words       = qr/[\w\p{P}\s]*\p{Han}+[\w\p{P}\s]*/;
  my $quote_left  = qr/\`/;
  my $quote_right = qr/\'/;

  my $pre_line;
  my @table_label;
  for ( @{$content_ref} ) {
    s/$quote_left{2} ($words) $quote_right{2}/“$1”/gx;
    s/$quote_left    ($words) $quote_right   /‘$1’/gx;
    s/\s+((?:表|图|公式)\~\\ref\{\w+\:\w+\})/$1/gx;
    if (m/^\\label\{(tbl\:[^}]+)\}/) {
      if ( $pre_line =~ m/^\\hypertarget\{$1\}/ ) {
        chomp($_);
        push @table_label, '\\caption{' . $_ . "}\\tabularnewline\n";
        $_ = "";
      }
    }
    if (m/^\\begin\{\w+table\}/) {
      $_ .= ( pop @table_label ) // "";
    }
    $pre_line = $_;
  }
}

sub str_adj_word {
  my $file = shift;
  my $cwd  = getcwd();
  my $dir  = tempdir( CLEANUP => 1 );
  system(qq/unzip -q "$file" -d "$dir"/);
  unlink $file;
  chdir "$dir";

  my $document_name = File::Spec->catfile( "word", "document.xml" );
  str_adj_file( $document_name, \&str_adj_word_documents );
  my $footnotes_name = File::Spec->catfile( "word", "footnotes.xml" );
  str_adj_file( $footnotes_name, \&str_adj_word_footnotes );

  system(qq/zip -r -q "$file" */) == 0 or die "zip error: $!";
  system( "mv", $file, $cwd ) if dirname($file) ne $cwd;
  chdir $cwd;
}

sub str_adj_word_documents {
  my $ori_content_ref = shift;
  my $content_ref     = str_group_by_paragraph( $ori_content_ref, "docx" );
  str_adj_etal($content_ref);

  my $nobreak_space = qr/ /u;

  # 公式没有上标，但有上标占位符的情况
  my $math_sup = qr/
      <m:sup> \s*
        <m:r> \s*
          <m:t>(?:\s|​|$nobreak_space)*<\/m:t> \s*
        <\/m:r> \s*
      <\/m:sup>
    /imx;

  my $tag_start    = qr/ <w:r> \s* <w:t \s xml:space="preserve"> /imx;
  my $tag_start_s  = qr/ <w:r> \s* <w:t>                         /imx;
  my $tag_end      = qr/ <\/w:t> \s* <\/w:r>                     /imx;
  my $tag_space    = qr/ $tag_start \s* $tag_end                 /imx;
  my $tag_par_l    = qr/ $tag_start \s* \( \s* $tag_end          /imx;
  my $tag_par_r    = qr/ $tag_start \s* \) \s* $tag_end          /imx;
  my $tag_ascii    = qr/ [A-z0-9_,;.\-()?:]                      /imx;
  my $digits_sign  = qr/ [^\(]+ \(\d{4},                         /imx;
  my $table_ref    = qr/表$nobreak_space\d+/u;
  my $figure_ref   = qr/图$nobreak_space\d+/u;
  my $equation_ref = qr/公式$nobreak_space\(\d+\)/u;

  # for match table caption
  my $bookmarkStart = qr{w:bookmarkStart \s+ w:id="\d+" \s w:name="[\w:]+"/> }imx;
  my $pStart        = qr{<w:p>};
  my $pPrStart      = qr{<w:pPr>};
  my $pPrEnd        = qr{</w:pPr>};
  my $tblPrefix     = qr/表 \d+:/;

  my $start = q{<w:r><w:t xml:space="preserve">};
  my $end   = q{</w:t></w:r>};
  for ( @{$content_ref} ) {

    # 比如 ab (2020, => ab(2020,
    s/$tag_start \s+ $tag_end ($tag_start $digits_sign)/$1/gimx;

    # \sum 上标
    s/$math_sup//gimx;

    # Convert English brackets after Chinese characters into Chinese brackets
    # 小明 (xxxx) => 小明（xxxx）
    s{ (?<!$tag_ascii) (?<before>\s* $tag_end \s*)
          (?:$tag_space \s*)* \s*
          $tag_par_l (?<after>.*?) $tag_par_r
      }{ $+{before}
          . $start . "（" . $end
          . $+{after}
          . $start . "）" . $end
      }eimxg;
    s{
          (?<!$tag_ascii|\s) \s* \( \s* (?<after>.*?) $tag_par_r
      }{
          "（" . $+{after} . $start . "）" . $end
      }iegmx;
    s{
          (?<!$tag_ascii|\s) \s* \( \s* (?<after>[^<)]{3,}) \s* \) \s*
      }{
          "（" . $+{after} . "）"
      }iegmx;

    # 替换交叉引用时引入的空格问题
    s{\s+($table_ref|$figure_ref|$equation_ref)}{$1}iugm;

    # 解决 pandoc-crossref 和 flextable 的兼容问题
    # 通过 lua-filter, pandoc-crossref 可以为 flextable 表格编号
    # 单表格标题会变成普通文本，
    # 我不知道如何在 pandoc 层面解决这个问题
    # 因此，只能采取正则匹配的笨办法
    s{($bookmarkStart \s+ $pStart \s+ $pPrStart \s+)
          <w:pStyle \s+ w:val="BodyText"/>
          (\s* $pPrEnd \s* $tag_start \s* $tblPrefix)
      }{$1<w:pStyle w:val="TableCaption"/>$2}gimx;

    # 删除中文标点符号后的空格
    my $tag_chinese_punc = qr/[（）。，：、]/u;
    s{ \s* ($tag_chinese_punc) \s* ($tag_end) \s* $tag_space }{$1$2}gimux;

    # 直角引号处理
    my $chinese_font_marker = qq{<w:rPr><w:rFonts w:hint="eastAsia"/><w:lang w:eastAsia="zh-CN"/> </w:rPr>};
    my $chinese_quote_left  = qq{<w:r>$chinese_font_marker<w:t>“</w:t></w:r>};
    my $chinese_quote_right = qq{<w:r>$chinese_font_marker<w:t>”</w:t></w:r>};
    s{「}{'</w:t></w:r>' . $chinese_quote_left  . '<w:r><w:t>'}ieug;
    s{」}{'</w:t></w:r>' . $chinese_quote_right . '<w:r><w:t>'}ieug;
  }
  return $content_ref;
}

sub str_group_by_paragraph {
  my ( $content_ref, $ext ) = @_;
  my %regex_paragraph_end_symbol = (
    docx => qr{\<\/w\:p\>},
    md   => qr{\A\s*\z},
  );
  my $end_symbol = $regex_paragraph_end_symbol{$ext};
  my @contents   = @$content_ref;
  for (@contents) {
    s{($end_symbol)}{\n$1\n}gimx unless "\n" =~ m/$end_symbol/;
    s{\n\s*\n}{\n}mxg;
  }

  my @contents_by_par;
  my $par = "";
  for my $l (@contents) {
    $par .= $l;
    if ( $l =~ m{$end_symbol} ) {
      push @contents_by_par, $par;
      $par = "";
    }
  }
  push @contents_by_par, $par unless $par eq "";
  return \@contents_by_par;
}

sub str_adj_word_footnotes {
  my $ori_content_ref = shift;
  my $content_ref     = str_group_by_paragraph( $ori_content_ref, "docx" );
  str_adj_etal($content_ref);
  for (@$content_ref) {

    # 直角引号处理
    my $chinese_font_marker = qq{<w:rPr><w:rFonts w:hint="eastAsia"/><w:lang w:eastAsia="zh-CN"/> </w:rPr>};
    my $chinese_quote_left  = qq{<w:r>$chinese_font_marker<w:t>“</w:t></w:r>};
    my $chinese_quote_right = qq{<w:r>$chinese_font_marker<w:t>”</w:t></w:r>};
    s{「}{'</w:t></w:r>' . $chinese_quote_left  . '<w:r><w:t>'}ieug;
    s{」}{'</w:t></w:r>' . $chinese_quote_right . '<w:r><w:t>'}ieug;
  }
  return $content_ref;
}

1;
