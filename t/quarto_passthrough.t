#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test::More;
use Path::Tiny;

use Fexport::Quarto qw(render_qmd);

# 回归测试：`fexport -t pdf x.qmd -- --bibliography=refs.json` 中 `--` 之后的
# 参数必须一路抵达 quarto 命令行。
#
# 背景：script/fexport 的 qmd 分支调用 render_qmd 时漏传 pandoc_opts
# （rmd 与 md 两条分支都传了），透传参数被静默丢弃。后果是逐级放大的：
#   --bibliography 丢失 -> citeproc 找不到任何条目 -> 引用渲染成 `key?`
#   -> 无参考文献 div -> pandoc 不设 csl-refs -> LaTeX 模板跳过 \citeproc
#   宏定义 -> xelatex 报 undefined control sequence 并返回 1
#   -> latexmk 中止在第一遍 -> 交叉引用永远停在 undefined。
# docx/html 不报错，只是同样静默丢掉了参考文献。
#
# 参数要穿过 render_qmd -> _run_quarto_with_metadata -> _build_quarto_command
# 三跳，任何一跳漏掉都会复现同一个 bug，所以两端都要盯：前半段用 stub 截住
# （真正调用 quarto 之前），后半段直接检查拼出来的命令行。全程不触达
# quarto 二进制，与 t/render_contract.t 一样无需外部工具。

# --- 前半段：render_qmd 是否把 pandoc_opts 交给下游 --------------------------

# 在 _run_quarto_with_metadata 处截停：记下收到的参数，随即抛出哨兵中止，
# 避免继续走到真正的 quarto 调用与后处理。
sub capture_downstream_args {
  my (%render_args) = @_;

  my %seen;
  no warnings 'redefine';
  local *Fexport::Quarto::_run_quarto_with_metadata = sub {
    %seen = @_;
    die "STOP\n";
  };

  eval { render_qmd( { infile => 'doc.qmd', to => 'pdf', outfile => 'doc.pdf', %render_args } ) };
  die "render_qmd 未在 stub 处中止：$@" unless $@ eq "STOP\n";

  return \%seen;
}

subtest 'render_qmd 把 pandoc_opts 传给下游' => sub {
  my $seen = capture_downstream_args( pandoc_opts => ['--bibliography=refs.json'] );

  is_deeply( $seen->{pandoc_opts}, ['--bibliography=refs.json'], 'pandoc_opts 抵达 _run_quarto_with_metadata' );
};

subtest 'render_qmd 缺省时归一化为空列表' => sub {
  my $seen = capture_downstream_args();

  is_deeply( $seen->{pandoc_opts}, [], '未传 pandoc_opts 时下游拿到空 arrayref，而非 undef' );
};

# --- 后半段：命令行拼装 ------------------------------------------------------

my %base = (
  infile_name   => 'doc.qmd',
  quarto_target => 'latex',
  local_outfile => path('doc.tex'),
  meta_data     => {},
  verbose       => 0,
);

subtest '透传参数原样附加在命令末尾' => sub {
  my @opts = ( '--bibliography=refs.json', '--csl=gb-t-7714.csl', '--metadata=link-citations:true' );
  my @cmd  = Fexport::Quarto::_build_quarto_command( %base, pandoc_opts => \@opts );

  is_deeply( [ @cmd[ -scalar(@opts) .. -1 ] ], \@opts, '顺序不变地落在命令末尾' );

  # 末尾意味着能覆盖 fexport 自己加的默认值（quarto/pandoc 均后者胜出）
  my ($quiet_idx) = grep { $cmd[$_] eq '--quiet' } 0 .. $#cmd;
  ok( defined $quiet_idx, '非 verbose 模式下带 --quiet' );
  cmp_ok( $#cmd - $#opts, '>', $quiet_idx, '透传参数位于内置选项之后' );
};

subtest '缺省与空列表不影响命令' => sub {
  my @without = Fexport::Quarto::_build_quarto_command(%base);
  my @empty   = Fexport::Quarto::_build_quarto_command( %base, pandoc_opts => [] );

  is_deeply( \@empty, \@without, '空的 pandoc_opts 不追加任何参数' );
  ok( ( grep { $_ eq 'quarto' } @without ), '命令仍以 quarto 开头' );
};

done_testing();
