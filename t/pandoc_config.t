use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use Data::Dump qw(dump);

use Fexport::Pandoc qw(build_cmd);
use Fexport::Config qw(load_config merge_config);

# Test default config
my $default_cmd = [ build_cmd(merge_config()->{pandoc}) ];
ok(scalar(@$default_cmd) > 0, "Default command is not empty");
is($default_cmd->[0], 'pandoc', "Default pandoc executable is correct");
ok((grep { $_ eq '+RTS' } @$default_cmd), "RTS flag present");
ok((grep { $_ eq '--filter=pandoc-crossref' } @$default_cmd), "Default filter present");

# Test overriding config
my ($fh, $filename) = tempfile();
print $fh <<YAML;
pandoc:
  cmd: my_pandoc
  filters:
    - --lua-filter=my-filter.lua
YAML
close $fh;

my $config = load_config($filename);
is($config->{pandoc}{cmd}, 'my_pandoc', "Config loaded: cmd override");
is_deeply($config->{pandoc}{filters}, ['--lua-filter=my-filter.lua'], "Config loaded: filters override");

my $custom_cmd = [ build_cmd(merge_config($config)->{pandoc}) ];
is($custom_cmd->[0], 'my_pandoc', "Built command uses custom executable");
ok((grep { $_ eq '--lua-filter=my-filter.lua' } @$custom_cmd), "Built command uses custom filter");

# Test params
my $param_cmd = [ build_cmd(merge_config($config)->{pandoc}, { verbose => 1, user_opts => '-F user-filter' }) ];
ok((grep { $_ eq '--verbose' } @$param_cmd), "Verbose flag added");
ok((grep { $_ eq '-F' } @$param_cmd), "User opts flag -F added");
ok((grep { $_ eq 'user-filter' } @$param_cmd), "User opts argument user-filter added");

done_testing();
unlink $filename;
