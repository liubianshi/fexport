#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Path::Tiny;

use Fexport::Quarto qw(render_qmd);
use Fexport::Rmd    qw(render_rmd);

# 回归测试：render_qmd / render_rmd 的参数契约。
#
# 背景：这两个渲染器被重构为「接收单个 hashref」，但 script/fexport
# 的调用方一度仍用位置参数 render_qmd($infile, $outfile, $verbose)，
# 导致 "$args->{infile}" 对一个 Path::Tiny 对象解引用而崩溃：
#   Not a HASH reference at Fexport/Quarto.pm line 43.
#
# 下列用例全部在函数入口的校验块内失败，不会触达 quarto / Rscript，
# 因此无需外部工具即可运行。

subtest 'render_qmd rejects positional (non-hashref) call' => sub {

  # 精确复现历史 bug：位置参数会把第一个实参 (Path::Tiny 对象) 当作 $args
  eval { render_qmd( path('foo.qmd'), path('foo.docx'), 0 ) };
  like( $@, qr/requires a single hash reference/, 'Path::Tiny first arg is rejected with a readable error' );

  eval { render_qmd('just-a-string') };
  like( $@, qr/requires a single hash reference/, 'plain scalar is rejected' );

  eval { render_qmd( [qw(a b c)] ) };
  like( $@, qr/requires a single hash reference/, 'array reference is rejected' );
};

subtest 'render_qmd validates required keys (proves hashref path is taken)' => sub {
  eval { render_qmd( {} ) };
  like( $@, qr/missing required argument: 'infile'/, 'empty hashref -> missing infile' );

  eval { render_qmd( { infile => 'x.qmd' } ) };
  like( $@, qr/missing required argument: 'to'/, 'infile only -> missing to' );

  eval { render_qmd( { infile => 'x.qmd', to => 'docx' } ) };
  like( $@, qr/missing required argument: 'outfile'/, 'infile+to -> missing outfile' );
};

subtest 'render_rmd rejects positional (non-hashref) call' => sub {

  # 旧调用方 render_rmd($infile, $outfile, $verbose) 会把 $outfile 误当格式、
  # 把标量 $verbose 误当 pandoc_opts 数组引用
  eval { render_rmd( path('foo.Rmd'), path('foo.html'), 0 ) };
  like( $@, qr/requires a single hash reference/, 'positional call is rejected with a readable error' );
};

subtest 'render_rmd validates required keys' => sub {
  eval { render_rmd( {} ) };
  like( $@, qr/missing required argument: 'infile'/, 'empty hashref -> missing infile' );

  eval { render_rmd( { infile => 'x.Rmd' } ) };
  like( $@, qr/missing required argument: 'to'/, 'infile only -> missing to' );
};

done_testing();
