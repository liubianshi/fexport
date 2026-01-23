package Fexport::PostProcess;

use v5.20;
use strict;
use warnings;
use utf8;
use Exporter 'import';

# 核心依赖
use Path::Tiny;
use Archive::Zip qw( :ERROR_CODES :CONSTANTS );
use XML::LibXML;
use Mojo::DOM;

our @EXPORT_OK = qw(
  postprocess_docx
  postprocess_html
  postprocess_latex
  sanitize_markdown_math
  fix_citation_etal
);

# ==============================================================================
# 1. DOCX 处理 (基于 XML DOM)
# ==============================================================================

sub postprocess_docx {
  my $docx_path = shift;
  # Archive::Zip requires a string path, not a Path::Tiny object
  $docx_path = "$docx_path";

  unless ( -e $docx_path ) {
    warn "[Warn] Docx file not found: $docx_path\n";
    return;
  }

  # 1. 读取 Zip (完全在内存中操作，不解压到磁盘)
  my $zip = Archive::Zip->new();
  unless ( $zip->read($docx_path) == AZ_OK ) {
    die "Failed to read docx file: $docx_path\n";
  }

  # 2. 定义需要处理的 XML 文件列表 (正文、脚注、样式)
  my @targets = ( 'word/document.xml', 'word/footnotes.xml', 'word/styles.xml' );

  for my $xml_file (@targets) {
    my $member = $zip->memberNamed($xml_file);
    next unless $member;    # 某些文档可能没有脚注，跳过

    # 解析 XML
    my $xml_content = $member->contents();
    my $dom         = XML::LibXML->load_xml( string => $xml_content );

    # 处理 DOM
    _process_docx_dom($dom);

    # 写回 Zip
    $member->contents( $dom->toString(0) );    # 0 = 不格式化输出，保持紧凑
  }

  # 3. 保存修改
  unless ( $zip->overwriteAs($docx_path) == AZ_OK ) {
    die "Failed to write back to docx: $docx_path\n";
  }
}

sub _process_docx_dom {
  my $dom = shift;
  my $xpc = XML::LibXML::XPathContext->new($dom);

  # 注册命名空间，DOCX 核心
  $xpc->registerNs( 'w', 'http://schemas.openxmlformats.org/wordprocessingml/2006/main' );
  $xpc->registerNs( 'm', 'http://schemas.openxmlformats.org/officeDocument/2006/math' );

  # --- A. 逻辑修复: 将 "表 X:" 的样式从 BodyText 改为 TableCaption ---
  # 查找所有样式为 BodyText 的段落节点
  for my $p_node ( $xpc->findnodes('//w:p[w:pPr/w:pStyle[@w:val="BodyText"]]') ) {

    # 获取该段落的所有文本
    my $text = $p_node->textContent;

    # 如果文本以 "表 数字:" 开头
    if ( $text =~ /^\s*表\s*\d+:/ ) {

      # 修改样式属性
      if ( my ($style_node) = $xpc->findnodes( 'w:pPr/w:pStyle', $p_node ) ) {
        $style_node->setAttribute( 'w:val', 'TableCaption' );
      }
    }
  }

  # --- B. 样式修复: 修正首行缩进 (2字符 vs 0.35cm 问题) ---
  for my $ind_node ( $xpc->findnodes('//w:ind[@w:firstLineChars="200"]') ) {
    if ( $ind_node->hasAttribute('w:firstLine') ) {
      $ind_node->removeAttribute('w:firstLine');
    }
  }

  # --- C. 文本修复: 按段落遍历所有文本节点 <w:t> ---
  # 改为按段落遍历，以维护段落内的上下文状态（如前一个字符是否为标点）
  for my $p_node ( $xpc->findnodes('//w:p') ) {
    my $last_char_is_punct = 0;

    # 查找段落内的所有 text 节点 (通常在 w:r 内部)
    # 注意：这里假设 w:t 都在 w:r 内，且顺序符合阅读顺序
    for my $text_node ( $xpc->findnodes( './/w:t', $p_node ) ) {
      my $text         = $text_node->textContent;
      my $original_len = length($text);

      # 0. 跨节点空格清理
      # 如果上一个节点以中文标点结尾，且当前节点以空白开头，则去除当前节点的开头空白
      if ($last_char_is_punct) {
        $text =~ s/^\s+//;
      }

      # 1. 修复 "et al." (中文 "等")
      $text =~ s/(?<=[a-zA-Z])(,\s|\s)等/et al./g;

      # 2. 修复 CJK 直角引号
      $text =~ s/「/“/g;
      $text =~ s/」/”/g;

      # 3. 英文括号转中文括号
      $text =~ s/\( ([^)]*?[\p{Han}]+[^)]*?) \)/（$1）/gx;

      # 4. 删除中文标点后的多余空格 (节点内)
      $text =~ s/([（）。，：、])\s+/$1/g;

      # 更新状态：检查当前节点末尾是否为中文标点
      # 注意：如果节点内容变空了（例如只剩空格被删除了），状态应该保持还是重置？
      # 这里逻辑：如果当前节点非空，则更新状态；如果变空了，理论上应该继承上一个状态？
      # 简化处理：只有非空内容才更新状态
      if ( length($text) > 0 ) {
        $last_char_is_punct = ( $text =~ /[（）。，：、]$/ );
      }

      # 仅当文本发生变化时才写回 DOM
      if ( length($text) != $original_len || $text ne $text_node->textContent ) {
        $text_node->removeChildNodes();
        # 必须保留 xml:space="preserve" 属性吗？
        # 如果 text 变空了，可能需要保留空节点或者删除？
        # Word 通常允许空 w:t，但最好保留
        $text_node->appendText($text);
      }
    }
  }
}

# ==============================================================================
# 2. HTML 处理 (基于 Mojo::DOM)
# ==============================================================================

sub postprocess_html {
  my $content_ref = shift;

  # 将数组内容合并为字符串供 DOM 解析
  my $html_string = join( "", @$content_ref );

  my $dom = Mojo::DOM->new($html_string);

  # 定义“不需要加空格”的字符结尾
  # 逻辑：如果前文以这些标点符号结尾（如逗号、句号、引号、左括号），则不应该加空格
  # 反之：如果以汉字、英文单词、数字结尾，则需要加空格
  state $no_space_punct = qr/[[:punct:]\s]$/u;

  # 注意：\s 包含换行和空格，如果已经有空格了，也不重复加

  # 查找所有引用节点
  $dom->find('span.citation')->each(
    sub {
      my $citation_el = shift;

      # 获取前一个节点 (Previous Sibling)
      my $prev = $citation_el->previous_node;

      # 仅当前一个节点是“文本节点”时才处理
      if ( $prev && $prev->type eq 'text' ) {
        my $text = $prev->content;

        # 核心逻辑：
        # 如果文本 **不是** 以标点或空白结尾的 (意味着是以汉字、字母、数字结尾)
        # 则追加一个空格
        unless ( $text =~ $no_space_punct ) {
          $prev->content( $text . ' ' );
        }
      }
    }
  );

  # 更新内容引用
  @$content_ref = ( $dom->to_string );
}

# ==============================================================================
# 3. LaTeX 处理 (正则状态机)
# ==============================================================================

sub postprocess_latex {
  my ($content_ref, $source_dir) = @_;

  # 预编译正则
  state $words       = qr/[\w\p{P}\s]*\p{Han}+[\w\p{P}\s]*/;
  state $quote_left  = qr/\`/;
  state $quote_right = qr/\'/;
  state $re_ref      = qr/\s+((?:表|图|公式)\~\\ref\{\w+\:\w+\})/;
  state $re_label    = qr/^\\label\{(tbl\:[^}]+)\}/;
  state $re_hyper    = qr/^\\hypertarget\{/;

  my $pre_line = "";
  my @table_labels;
  
  # ... (macro injection block unchanged) ...
  
  # 0. 注入 pandocbounded 兼容性宏 (Pandoc 3.x+ 生成的新命令，老模板可能缺失)
  my $pandoc_bounded_macro = <<'EOF';
\makeatletter
\@ifundefined{pandocbounded}{%
  \newsavebox\pandoc@box
  \newcommand*\pandocbounded[1]{%
    \sbox\pandoc@box{#1}%
    \ifdim\wd\pandoc@box>\linewidth
      \resizebox{\linewidth}{!}{\usebox\pandoc@box}%
    \else
      \usebox\pandoc@box
    \fi
  }
}{}
\makeatother
EOF

  # 将宏插入到 \begin{document} 之前 (最安全的位置)
  my $inserted = 0;

  for (my $i = 0; $i < @{$content_ref}; $i++) {
    if ($content_ref->[$i] =~ /^\s*\\begin\{document\}/) {
      splice @{$content_ref}, $i, 0, $pandoc_bounded_macro;
      $inserted = 1;
      last;
    }
  }
  
  # Fallback: 插入到最前面 (仅当找不到 document 时，可能有风险但好过不插)
  unless ($inserted) {
    unshift @{$content_ref}, $pandoc_bounded_macro;
  }

  for ( @{$content_ref} ) {

    # 1. 中文直角引号修复
    s/$quote_left{2} ($words) $quote_right{2}/“$1”/gx;
    s/$quote_left    ($words) $quote_right   /‘$1’/gx;

    # 2. 引用空格修复
    s/$re_ref/$1/gx;

    # 3. Table Caption 位置调整 (Pandoc 下置 -> 上置)
    if (m/$re_label/) {
      my $lbl = $1;

      # 检查上一行是否是对应的 hypertarget
      if ( $pre_line =~ /$re_hyper\Q$lbl\E\}/ ) {
        chomp($_);    # 移除换行
                      # 保存 Caption 到栈中
        push @table_labels, '\\caption{' . $_ . "}\\tabularnewline\n";
        $_ = "";      # 清空当前行 (Caption 被移走了)
      }
    }

    # 当遇到表格开始时，插入之前保存的 Caption
    if (m/^\\begin\{\w+table\}/) {
      $_ .= ( pop @table_labels ) // "";
    }

    # 4. Fix paths:
    #   a) absolute paths corrupted by Quarto (./tmp/foo -> /tmp/foo)
    #   b) relative paths in subdirectories (img/foo -> doc/img/foo)
    s/(\\includegraphics(?:\[[^\]]*\])?\{)([^\}]+)\}/_fix_image_path($1, $2, $source_dir)/gex;

    $pre_line = $_;
  }
}

# ==============================================================================
# 4. 其他辅助函数
# ==============================================================================

sub sanitize_markdown_math {
  my $content_ref = shift;
  state $math_sign = qr/\$\$/;
  state $eq_begin  = qr/\\begin\{equa[^\}]+\}/;
  state $eq_end    = qr/\\end\{equa[^\}]+\}/;

  for ( @{$content_ref} ) {
    s/$math_sign ($eq_begin)/$1/gx;
    s/($eq_end) [^\$]* $math_sign/$1/gx;
  }
}

sub fix_citation_etal {
  my $content_ref = shift or return;

  # 通用文本修复：用于纯文本上下文
  state $re_etal  = qr/(?<=[a-zA-Z])(,\s|\s)等/m;
  state $re_clean = qr/\s(等(?:\s\(|（|,\s|<\/a>|<\/w:t>))/;

  for ( @{$content_ref} ) {
    s/$re_etal/$1et al./g;
    s/$re_clean/$1/g;
  }
}

1;

sub _fix_image_path {
  my ($prefix, $path_str, $source_dir) = @_;
  my $fixed = $prefix . $path_str . "}";
  
  # Case a: Quarto corrupted absolute path (./tmp/... -> /tmp/...)
  if ($path_str =~ /^\.\//) {
      my $abs_candidate = substr($path_str, 1); # remove leading .
      if (-e $abs_candidate) {
          return $prefix . $abs_candidate . "}";
      }
  }
  
  # Case b: Relative path from subdir (only if not fixed by Case a and doesn't exist in root)
  if (! -e $path_str && $source_dir && $path_str !~ /^\//) {
      my $rel_path = path($source_dir)->child($path_str);
      if ($rel_path->exists) {
           return $prefix . $rel_path . "}";
      }
  }
  
  return $fixed;
}
