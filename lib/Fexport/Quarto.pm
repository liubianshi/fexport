package Fexport::Quarto;
use strict;
use warnings;
use v5.20;
use Exporter 'import';
use YAML qw(LoadFile DumpFile);
use File::Spec;
use File::Copy           qw(move);
use Scope::Guard         qw(guard);
use Fexport::Util        qw(write2file get_resource_path);
use Fexport::PostProcess qw(str_adj_etal str_adj_html str_adj_tex str_adj_word);
use File::Temp           qw(tempdir);
use FindBin              qw($RealBin);

our @EXPORT_OK = qw(render_qmd);

=head2 render_qmd

Renders a Quarto markdown file to various output formats.

=over 4

=item * C<$infile> - Input Quarto markdown file path

=item * C<$outformat> - Desired output format (html, pdf, docx, etc.)

=item * C<$outfile> - Output file path

=item * C<$LANG> - Language code for document processing

=item * C<$PREVIEW> - Boolean flag to enable browser preview mode

=item * C<$VERBOSE> - Boolean flag for verbose output

=item * C<$KEEP_INTERMEDIATES> - Boolean flag to preserve intermediate files

=item * C<$OUTFILE> - Final output file path

=back

Returns: None (dies on error)

=cut

sub render_qmd {
  my ( $infile, $outformat, $outfile, $LANG, $PREVIEW, $VERBOSE, $KEEP_INTERMEDIATES, $OUTFILE ) = @_;

  # Load Quarto options and determine intermediate format
  # Quarto/Pandoc --from format differs from output file extension
  # (e.g., beamer outputs to .pdf, not .beamer)
  my $quarto_options = LoadFile( get_resource_path("quarto_option.yaml") );
  my $format_config  = $quarto_options->{$outformat} // {};

  my $quarto_target     = $format_config->{intermediate}     // $outformat;
  my $quarto_target_ext = $format_config->{intermediate_ext} // $quarto_target;

  # Adjust output file extension if intermediate format differs
  $outfile =~ s/\.\w+$/"." . $quarto_target_ext/e if $quarto_target_ext ne $outformat;
  $outformat = $format_config->{ext} // $outformat;

  # Backup and restore _metadata.yml if it exists
  my ( $metadata_exist, $metadata_generated ) = ( 0, 0 );
  my $guard = guard {
    unlink "_metadata.yml" if $metadata_generated;
    move "_metadata.yml_bck" => "_metadata.yml" if $metadata_exist;
  };

  if ( -e "_metadata.yml" ) {
    move "_metadata.yml" => "_metadata.yml_bck" and $metadata_exist = 1;
  }

  # Load and merge metadata from Pandoc defaults and existing _metadata.yml
  my $defaults_path = "$ENV{HOME}/.pandoc/defaults/2${quarto_target}.yaml";
  my $meta_data     = load_pandoc_defaults($defaults_path);

  if ( -e -r "_metadata.yml_bck" ) {
    merge_yaml( $meta_data, LoadFile("_metadata.yml_bck") );
  }

  # Resolve template paths to absolute paths for Quarto compatibility
  if ( exists $meta_data->{template}
    && ref $meta_data->{template} eq ''
    && !File::Spec->file_name_is_absolute( $meta_data->{template} ) )
  {

    $meta_data->{template} .= ".${quarto_target}" unless $meta_data->{template} =~ /\.\w+$/;
    $meta_data->{template} = File::Spec->catfile( $ENV{HOME}, ".pandoc", "templates", $meta_data->{template} );
  }

  DumpFile( "_metadata.yml", $meta_data ) and $metadata_generated = 1;

  # Override language if specified in metadata
  $LANG = $meta_data->{lang} if $meta_data->{lang};

  # Execute Quarto render with Lua filters
  my @quarto_cmd = (
    "quarto",       "render", $infile, "--to", $quarto_target, "--output", $outfile,
    "--lua-filter", "$ENV{HOME}/.pandoc/filters/quarto_docx_embeded_table.lua",
    "--lua-filter", "$ENV{HOME}/.pandoc/filters/rsbc.lua"
  );

  system(@quarto_cmd) == 0 or die "Failed to run quarto: $?";

  # Clean up temporary metadata files early on success
  unlink "_metadata.yml" if $metadata_generated;
  move "_metadata.yml_bck" => "_metadata.yml" if $metadata_exist;
  $guard->dismiss();

  # Post-process output based on format
  _process_html_output( $outfile, $PREVIEW, $OUTFILE )                               if $outformat eq "html";
  _process_pdf_output( $outfile, $quarto_target_ext, $VERBOSE, $KEEP_INTERMEDIATES ) if $outformat eq "pdf";
  _process_docx_output( $outfile, $LANG )                                            if $outformat eq "docx";
}

=head2 _process_html_output

Post-processes HTML output with adjustments and optional browser preview.

=over 4

=item * C<$outfile> - Path to HTML output file

=item * C<$PREVIEW> - Boolean flag for preview mode

=item * C<$OUTFILE> - Final output file path

=back

=cut

sub _process_html_output {
  my ( $outfile, $PREVIEW, $OUTFILE ) = @_;

  open my $fh, "<", $outfile or die "Cannot open $outfile: $!";
  my @html_contents = <$fh>;
  close $fh;

  # Apply HTML-specific adjustments
  str_adj_etal( \@html_contents );
  str_adj_html( \@html_contents );

  # Modify title for preview mode
  if ($PREVIEW) {
    for (@html_contents) {
      last if s/^(\s*<title>).+(<\/title>)\s*$/${1}quarto_preview_in_browser${2}/;
    }
  }

  write2file( \@html_contents, $OUTFILE );

  # Launch or refresh browser preview
  if ($PREVIEW) {
    my $current_win_id = qx/xdotool getactivewindow/;
    chomp $current_win_id;

    my $surf_window_id = qx(xdotool search --onlyvisible --name quarto_preview_in_browser | head -n 1);
    chomp $surf_window_id;

    if ( !$surf_window_id ) {
      exec qq(setsid surf "$OUTFILE" &>/dev/null);
    }

    exec qq(
      xdotool windowactivate --sync $surf_window_id key --clearmodifiers ctrl+r && \\
      xdotool windowactivate $current_win_id
    );
  }
}

=head2 _process_pdf_output

Converts intermediate LaTeX to PDF using latexmk.

=over 4

=item * C<$outfile> - Path to intermediate LaTeX file

=item * C<$quarto_target_ext> - Extension of intermediate format

=item * C<$VERBOSE> - Boolean flag for verbose output

=item * C<$KEEP_INTERMEDIATES> - Boolean flag to preserve intermediate files

=back

=cut

sub _process_pdf_output {
  my ( $outfile, $quarto_target_ext, $VERBOSE, $KEEP_INTERMEDIATES ) = @_;

  open my $fh, "<", $outfile or die "Cannot open $outfile: $!";
  my @tex_contents = <$fh>;
  close $fh;

  # Apply LaTeX-specific adjustments
  str_adj_tex( \@tex_contents );

  # Compile LaTeX to PDF in temporary directory
  my $dir          = tempdir( CLEANUP => 1 );
  my $intermediate = File::Spec->catfile( $dir, "intermediate.tex" );
  write2file( \@tex_contents, $intermediate );

  my $latexmk_cmd =
    $VERBOSE
    ? qq/latexmk -xelatex -outdir="$dir" "$intermediate"/
    : qq/latexmk -quiet -xelatex -outdir="$dir" "$intermediate"/;

  system($latexmk_cmd) == 0 or die "Failed to render LaTeX file: $?";

  # Clean up intermediate LaTeX file unless requested to keep
  unlink $outfile unless $KEEP_INTERMEDIATES;

  # Move final PDF to target location
  my $target_file = $outfile =~ s/${quarto_target_ext}$/pdf/r;
  move "$dir/intermediate.pdf" => $target_file;
  say $target_file;
}

=head2 _process_docx_output

Post-processes DOCX output for Chinese language support.

=over 4

=item * C<$outfile> - Path to DOCX output file

=item * C<$LANG> - Language code

=back

=cut

sub _process_docx_output {
  my ( $outfile, $LANG ) = @_;
  str_adj_word($outfile) if $LANG eq "zh";
}

=head2 merge_yaml

Recursively merges two YAML/hash structures, with source overriding destination.

=over 4

=item * C<$dest> - Destination hash reference (modified in place)

=item * C<$src> - Source hash reference

=back

Returns: None (modifies C<$dest> in place)

=cut

sub merge_yaml {
  my ( $dest, $src ) = @_;

  while ( my ( $key, $val_src ) = each %$src ) {

    # Direct assignment if key doesn't exist in destination
    if ( !exists $dest->{$key} ) {
      $dest->{$key} = $val_src;
      next;
    }

    my $val_dest = $dest->{$key};
    my $r_dest   = ref $val_dest || '';
    my $r_src    = ref $val_src  || '';

    # Recursively merge nested hashes
    if ( $r_dest eq 'HASH' && $r_src eq 'HASH' ) {
      merge_yaml( $val_dest, $val_src );
    }

    # Merge and deduplicate arrays
    elsif ( $r_dest eq 'ARRAY' && $r_src eq 'ARRAY' ) {
      my %seen;
      $dest->{$key} = [ grep { defined $_ ? !$seen{$_}++ : 1 } @$val_dest, @$val_src ];
    }

    # Overwrite for type mismatches or scalar values
    else {
      $dest->{$key} = $val_src;
    }
  }
}

=head2 substitute_environment_variable

Recursively substitutes environment variables in strings, hashes, and arrays.
Modifies data structure in place using aliasing.

=over 4

=item * C<$_[0]> - Scalar, hash ref, array ref, or scalar ref to process

=back

Returns: None (modifies input in place)

=cut

sub substitute_environment_variable {

  # Use $_[0] directly for in-place modification via aliasing
  return unless defined $_[0];

  my $ref = ref $_[0];

  # Process scalar values
  if ( !$ref ) {
    $_[0] =~ s/\$[{]?(\w+)[}]?/$ENV{$1} \/\/ ''/eeg;
    return;
  }

  # Recursively process hash values
  if ( $ref eq 'HASH' ) {
    substitute_environment_variable($_) for values %{ $_[0] };
  }

  # Recursively process array elements
  elsif ( $ref eq 'ARRAY' ) {
    substitute_environment_variable($_) for @{ $_[0] };
  }

  # Dereference and process scalar references
  elsif ( $ref eq 'SCALAR' ) {
    substitute_environment_variable( ${ $_[0] } );
  }
}

=head2 load_pandoc_defaults

Loads Pandoc defaults YAML file and substitutes environment variables.

=over 4

=item * C<$file> - Path to Pandoc defaults YAML file

=back

Returns: Hash reference of loaded and processed YAML data, or undef if file not readable

=cut

sub load_pandoc_defaults {
  my $file = shift or return;
  return unless -r $file;

  my $yaml = LoadFile($file);
  substitute_environment_variable($yaml);
  return $yaml;
}

1;

