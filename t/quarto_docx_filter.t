#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use open qw(:std :utf8);
use Test::More;
use JSON::PP  qw(decode_json);
use IPC::Cmd  qw(can_run);
use IPC::Run3 qw(run3);
use Path::Tiny;

my $pandoc = can_run('pandoc') or plan skip_all => '需要 pandoc 来执行 Lua 过滤器回归测试';
my $filter = path(__FILE__)->parent->parent->child('share/quarto_docx_embeded_table.lua')->realpath;

sub citation {
  my ($id) = @_;
  return {
    citationId      => $id,
    citationPrefix  => [],
    citationSuffix  => [],
    citationMode    => { t => 'NormalCitation' },
    citationNoteNum => 1,
    citationHash    => 0,
  };
}

my $document = {
  'pandoc-api-version' => [ 1, 23, 1, 2 ],
  meta                 => {},
  blocks               => [
    {
      t => 'Para',
      c => [
        {
          t => 'Cite',
          c => [
            [ citation('note') ],
            [
              {
                t => 'Note',
                c => [
                  {
                    t => 'Para',
                    c => [ { t => 'Str', c => '脚注引文' } ]
                  }
                ]
              }
            ],
          ],
        },
        { t => 'Space' },
        {
          t => 'Cite',
          c => [
            [ citation('chinese') ], [ { t => 'Str', c => '(小明' }, { t => 'Space' }, { t => 'Str', c => '2029)' } ],
          ],
        },
      ],
    },
  ],
};

my $input  = JSON::PP->new->utf8->encode($document);
my $output = '';
my $error  = '';
run3 [ $pandoc, '--from=json', '--to=json', "--lua-filter=$filter" ], \$input, \$output, \$error;
my $exit_code = $? >> 8;

is( $exit_code, 0, 'note 类引文不会让 Lua 过滤器崩溃' ) or diag $error;
SKIP: {
  skip 'Pandoc 执行失败，无法检查输出 AST', 4 unless $exit_code == 0;

  my $result       = decode_json($output);
  my $inlines      = $result->{blocks}[0]{c};
  my $note_content = $inlines->[0]{c}[1];
  my $text_content = $inlines->[2]{c}[1];

  is( $note_content->[0]{t},             'Note',  'note 引文仍保持 Note 节点' );
  is( $note_content->[0]{c}[0]{c}[0]{c}, '脚注引文',  'note 引文内容不被括号逻辑改写' );
  is( $text_content->[0]{c},             '（小明',   '中文文本引文的左括号仍转换为全角' );
  is( $text_content->[2]{c},             '2029）', '中文文本引文的右括号仍转换为全角' );
}

done_testing();
