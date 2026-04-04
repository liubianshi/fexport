use strict;
use warnings;
use utf8;
use Test::More;
use Fexport::Config  qw(merge_config process_params);
use Fexport::Pandoc  qw(build_cmd);
use Path::Tiny;
use File::Temp qw(tempdir);

# 准备测试环境
my $dir = tempdir(CLEANUP => 1);
my $md_file = path($dir)->child("test.md");
my $chinese_content = "测试中文：你好，世界";
$md_file->spew_utf8("---\ntitle: $chinese_content\n---\n\n$chinese_content\n");

# 模拟参数处理
my $params = { to => 'latex', from => 'md' };
my $config = merge_config(undef, $params);
my ($work_dir, $infile, $outfile) = process_params($config, $md_file->stringify, $dir);

# 构建命令
my @cmd = build_cmd($config->{pandoc}, $config);
push @cmd, "--to", "latex", "--output", $outfile, $infile;

# 执行命令 (chdir 到工作目录)
my $cwd = Path::Tiny->cwd;
chdir $work_dir;
my $output = `@cmd 2>&1`;
my $exit_code = $? >> 8;
chdir $cwd;

is($exit_code, 0, "Pandoc executed successfully for latex output") or diag("Output: $output");

# 验证生成的 tex 文件
my $tex_path = path($work_dir)->child($outfile);
ok($tex_path->exists, "Latex file was generated at $tex_path");

# 使用二进制方式读取并尝试解码，或者直接使用 slurp_utf8
my $tex_content = eval { $tex_path->slurp_utf8 };
ok(!$@, "Latex file can be read as UTF-8") or diag("Error: $@");
like($tex_content, qr/\Q$chinese_content\E/, "Latex file contains correct Chinese content without garbling");

done_testing();
