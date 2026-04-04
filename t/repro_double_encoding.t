use strict;
use warnings;
use utf8;
use Test::More;
use Fexport::Pandoc qw(build_cmd);
use Path::Tiny;
use Encode qw(is_utf8 encode_utf8);

# 罗伟 的正确 UTF-8 字节序列
my $expected_bytes = "\xe7\xbd\x97\xe4\xbc\x9f"; 

# 模拟一个从环境变量或命令行通过 @ARGV 获取的字符串（无 flag 的字节）
# 这是最常见的乱码源头：Perl 获取外部输入时默认不带 flag
my $raw_input = "\xe7\xbd\x97\xe4\xbc\x9f"; 
ok(!is_utf8($raw_input), "External input lacks UTF8 flag");

my $params = {
    format_opts => {
        metadata => {
            author => [$raw_input],
        },
    },
    verbose => 0,
};

# 调用 build_cmd
my @cmd = build_cmd({}, $params);

# 提取生成的 defaults 文件路径
my $defaults_file;
for (my $i = 0; $i < @cmd; $i++) {
    if ($cmd[$i] eq '--defaults') {
        $defaults_file = $cmd[$i+1];
        last;
    }
}

ok($defaults_file && -f $defaults_file, "Defaults file was generated");

# 以二进制（raw）模式读取文件内容，不进行任何解码
my $raw_content = path($defaults_file)->slurp_raw;

# 检查文件中是否包含正确的字节序列，还是被错误地双重编码了
if ($raw_content =~ /\Q$expected_bytes\E/ && $raw_content !~ /\xc3\xa7/) {
    pass("File contains correct UTF-8 bytes for '罗伟'");
} else {
    my $hex = unpack("H*", $raw_content);
    fail("REPRODUCED! Double encoding detected. Hex: $hex");
}

done_testing();
