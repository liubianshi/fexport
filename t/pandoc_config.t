use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use Data::Dump qw(dump);

use_ok('Fexport::Pandoc', qw(build_cmd load_config));

# Test default config
my $default_cmd = [ build_cmd() ];
ok(scalar(@$default_cmd) > 0, "Default command is not empty");
is($default_cmd->[0], 'pandoc +RTS -M512M -RTS', "Default pandoc executable is correct");
ok((grep { $_ eq '--filter=pandoc-crossref' } @$default_cmd), "Default filter present");

# Test overriding config
my ($fh, $filename) = tempfile();
print $fh <<YAML;
cmd: my_pandoc
filters:
  - --lua-filter=my-filter.lua
YAML
close $fh;

my $config = load_config($filename);
is($config->{cmd}, 'my_pandoc', "Config loaded: cmd override");
is_deeply($config->{filters}, ['--lua-filter=my-filter.lua'], "Config loaded: filters override");

my $custom_cmd = [ build_cmd($config) ];
is($custom_cmd->[0], 'my_pandoc', "Built command uses custom executable");
ok((grep { $_ eq '--lua-filter=my-filter.lua' } @$custom_cmd), "Built command uses custom filter");

# Test params
my $param_cmd = [ build_cmd($config, { verbose => 1, user_opts => '-F user-filter' }) ];
ok((grep { $_ eq '--verbose' } @$param_cmd), "Verbose flag added");
ok((grep { $_ eq '-F user-filter' } @$param_cmd), "User opts added");

done_testing();
unlink $filename;
