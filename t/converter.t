use strict;
use warnings;
use Test::More;
use File::Temp;
use Cwd qw(getcwd);
use Path::Tiny;

# 1. Preload dependencies or modules that need REAL system (like IPC::Run3 via Fexport::Util)
# This must happen BEFORE overriding CORE::GLOBAL::system
# 1. Preload dependencies or modules that need REAL system (like IPC::Run3 via Fexport::Util)
# This must happen BEFORE overriding CORE::GLOBAL::system
use Fexport::Util;

# 2. Setup Global Mocking for 'system'

# 2. Setup Global Mocking for 'system'
# This must happen in a BEGIN block.
# Modules loaded AFTER this will see the mocked system.
my $mock_system_handler;
BEGIN {
    *CORE::GLOBAL::system = sub {
        my @args = @_;
        print STDERR "Mock system called with: " . join(" ", @args) . "\n";
        if ($mock_system_handler) {
            return $mock_system_handler->(@_);
        }
        return 0; # Default success
    };
}

# 3. Load modules that we want to MOCK system calls in (Fexport::Converter)
# 3. Load modules that we want to MOCK system calls in (Fexport::Converter)
use Fexport::Converter qw(convert);

# 4. Setup execution environment (Temp Directory)
my $temp_dir = File::Temp->newdir();
my $orig_cwd = getcwd();
chdir $temp_dir or die "Could not chdir to temp dir: $!";

# 4. Mocking Internal Helpers
{
    no warnings 'redefine';
    no warnings 'once';

    # Mock Fexport::Util/Converter helpers
    *Fexport::Converter::md2array = sub { 1 };
    *Fexport::Converter::md2file  = sub { 1 };
    *Fexport::Converter::write2file = sub { 1 };
    *Fexport::Converter::pandoc_opts_default = sub { "" };
    
    *Fexport::Converter::str_adj_etal = sub { 1 };
    *Fexport::Converter::str_adj_html = sub { 1 };
    *Fexport::Converter::str_adj_word = sub { 1 };
    *Fexport::Converter::fix_citation_etal = sub { 1 };
    *Fexport::Converter::postprocess_html = sub { 1 };
    *Fexport::Converter::postprocess_latex = sub { 1 };
    *Fexport::Converter::sanitize_markdown_math = sub { 1 };
    *Fexport::Converter::get_pandoc_defaults_flag = sub { "" }; # Moved up/consolidated
    
    # save_lines must actually save if we want files to exist for subsequent steps?
    # Or we can just mock the steps that consume them.
    # In _to_pdf, save_lines creates intermediate.tex. latexmk consumes it.
    # If we mock latexmk (via system), we don't strictly need the file if our mock doesn't check it.
    *Fexport::Converter::save_lines = sub { 
        my ($lines, $file) = @_;
        path($file)->touch; # Create empty file to satisfy existence checks
    };

    *Fexport::Converter::run_pandoc_and_load = sub { return ("Simulated Content") };
    *Fexport::Converter::run_pandoc = sub { 1 };
    *Fexport::Converter::get_pandoc_defaults_flag = sub { "--defaults=test" };
}

# 5. Create fake latexmk for testing
my $fake_latexmk = path($temp_dir)->child('latexmk');
$fake_latexmk->spew(<<'EOF');
#!/usr/bin/env perl
use strict;
use warnings;
use Path::Tiny;

my @args = @ARGV;
# Debug
if ($^O eq 'linux') {
    open my $fh, '>>', '/tmp/shim_debug.log';
    print $fh "Shim called with: " . join(" ", @args) . "\n";
    close $fh;
}

# Find outdir
my ($outdir_arg) = grep { /^-outdir=/ } @args;
my $outdir = '.';
if ($outdir_arg && $outdir_arg =~ /^-outdir=(.+)$/) {
    $outdir = $1;
}

# Create intermediate.pdf
path($outdir)->child('intermediate.pdf')->touch;
exit 0;
EOF

$fake_latexmk->chmod(0755);
$ENV{PATH} = path($temp_dir)->stringify . ":" . $ENV{PATH};

# 6. Tests

# Test HTML dispatch with preview
# Mock launch_browser_preview (now in Fexport::Util)
my $preview_called = 0;
# Mock launch_browser_preview (Mock the symbol imported into Converter)
no warnings 'redefine';
*Fexport::Converter::launch_browser_preview = sub {
    $preview_called = 1; # Use outer scope variable
    return;
};

# Test HTML dispatch with preview
{
    $mock_system_handler = sub { return 0; };
    $preview_called = 0;
    
    eval {
        convert({
            format      => 'html',
            outfile     => 'test.html',
            md_contents => [],
            pandoc      => ['pandoc'],
            log_fh      => *STDOUT,
            preview     => 1,
        });
    };
    is($@, '', "HTML conversion with preview works without error");
    ok($preview_called, "launch_browser_preview was called for preview");
}

# ...

# Test PDF dispatch with keep
{

    


    eval {
        convert({
            format      => 'pdf',
            outfile     => 'test.pdf',
            md_contents => [],
            pandoc      => ['pandoc'],
            log_fh      => *STDOUT,
            verbose     => 0,
            keep        => 1,
        });
    };
    is($@, '', "PDF conversion with keep works without error");
    ok(-f "test.pdf", "PDF file was moved to final destination");
}

# Test Default dispatch
{
    $mock_system_handler = undef; 
    eval {
        convert({
            format      => 'plain',
            outfile     => 'test.txt',
            md_contents => [],
            pandoc      => ['pandoc'],
            log_fh      => *STDOUT,
        });
    };
    is($@, '', "Default conversion dispatch works without error");
}

# Cleanup
chdir $orig_cwd;
done_testing();
