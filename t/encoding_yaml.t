use strict;
use warnings;
use utf8;
use Test::More;
use Fexport::Pandoc qw(build_cmd);
use Path::Tiny;
use YAML::XS qw(LoadFile);
use JSON::PP;

# 1. 模拟包含中文字符的 format_opts
my $chinese_text = "测试中文内容";
my $params = {
    format_opts => {
        metadata => {
            author => [$chinese_text],
            title  => "中文标题",
        },
        citeproc => JSON::PP::true,
    },
    verbose => 1,
};

# 2. 调用 build_cmd 生成命令和临时 YAML 文件
my @cmd = build_cmd({}, $params);

# 3. 从生成的命令中提取 --defaults 后面的文件路径
my $defaults_file;
for (my $i = 0; $i < @cmd; $i++) {
    if ($cmd[$i] eq '--defaults') {
        $defaults_file = $cmd[$i+1];
        last;
    }
}

ok($defaults_file, "Found generated defaults file: $defaults_file");
ok(-f $defaults_file, "Defaults file exists");

# 4. 验证文件内容
# 使用 path()->slurp_utf8 确保以 UTF-8 读取
my $content = path($defaults_file)->slurp_utf8;
like($content, qr/$chinese_text/, "Content contains correct Chinese text without garbling");
unlike($content, qr/\\x/, "Content does not contain escaped hex sequences");

# 5. 验证 YAML 是否能被正确解析回 Perl
my $data = eval { LoadFile($defaults_file) };
ok(!$@, "YAML is valid and loadable") or diag($@);
is($data->{metadata}->{author}->[0], $chinese_text, "Parsed Chinese text matches original");
is($data->{citeproc}, 1, "Boolean true is correctly serialized");

done_testing();
