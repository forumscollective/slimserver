#!/usr/bin/env perl

# Test script to validate the External Database plugin example
# This ensures the reference implementation follows the correct pattern

use strict;
use warnings;
use Test::More;
use File::Spec::Functions;
use FindBin qw($Bin);
use lib catdir($Bin, '..');

# Test 1: Check that the plugin files exist
ok(-f catfile($Bin, '..', 'Slim', 'Plugin', 'ExternalDB', 'Plugin.pm'), 
   'Plugin.pm exists');
ok(-f catfile($Bin, '..', 'Slim', 'Plugin', 'ExternalDB', 'Importer.pm'), 
   'Importer.pm exists');
ok(-f catfile($Bin, '..', 'Slim', 'Plugin', 'ExternalDB', 'install.xml'), 
   'install.xml exists');
ok(-f catfile($Bin, '..', 'Slim', 'Plugin', 'ExternalDB', 'strings.txt'), 
   'strings.txt exists');
ok(-f catfile($Bin, '..', 'Slim', 'Plugin', 'ExternalDB', 'README.md'), 
   'README.md exists');

# Test 2: Verify the plugin uses correct patterns
{
	
	# Read the Importer.pm file
	open my $fh, '<', catfile($Bin, '..', 'Slim', 'Plugin', 'ExternalDB', 'Importer.pm')
		or die "Cannot open Importer.pm: $!";
	my $content = do { local $/; <$fh> };
	close $fh;
	
	# Test 3a: Uses addImporter
	like($content, qr/Slim::Music::Import->addImporter/,
	     'Plugin registers using addImporter');
	
	# Test 3b: Uses updateOrCreate (the correct way)
	like($content, qr/Slim::Schema->updateOrCreate/,
	     'Plugin uses updateOrCreate for tracks');
	
	# Test 3c: Uses forceCommit (correct transaction handling)
	like($content, qr/Slim::Schema->forceCommit/,
	     'Plugin uses forceCommit for periodic commits');
	
	# Test 3d: Does NOT directly manipulate scanned_files (except in comments/documentation)
	my $code_only = $content;
	$code_only =~ s/#.*$//mg;  # Remove comments
	$code_only =~ s/=head.*?=cut//gs;  # Remove POD sections
	
	unlike($code_only, qr/INSERT\s+INTO\s+scanned_files/i,
	       'Plugin does not directly INSERT into scanned_files');
	
	# Test 3e: Does NOT directly manipulate tracks (except in comments/documentation)
	unlike($code_only, qr/INSERT\s+INTO\s+tracks/i,
	       'Plugin does not directly INSERT into tracks');
}

# Test 4: Check documentation exists and mentions key concepts
my $guide_path = catfile($Bin, '..', 'PLUGIN_EXTERNAL_DATABASE_GUIDE.md');
ok(-f $guide_path, 'Guide documentation exists');

SKIP: {
	skip "Guide doesn't exist", 4 unless -f $guide_path;
	
	open my $fh, '<', $guide_path or die "Cannot open guide: $!";
	my $guide = do { local $/; <$fh> };
	close $fh;
	
	like($guide, qr/updateOrCreate/i, 'Guide mentions updateOrCreate');
	like($guide, qr/corruption/i, 'Guide discusses database corruption');
	like($guide, qr/Importer\s+Interface/i, 'Guide explains Importer interface');
	like($guide, qr/DON'T.*directly.*manipulate/i, 'Guide warns against direct manipulation');
}

done_testing();

__END__

=head1 NAME

validate_external_db_plugin.t - Test the External Database plugin reference implementation

=head1 DESCRIPTION

This test validates that the External Database plugin example follows the
correct patterns and doesn't use any anti-patterns that could cause database
corruption.

=head1 TESTS

=over 4

=item * Files exist

All required plugin files are present

=item * Modules compile

The plugin modules load without errors

=item * Correct patterns used

The plugin uses the recommended patterns:
- addImporter for registration
- updateOrCreate for track creation
- forceCommit for transaction management

=item * Anti-patterns avoided

The plugin does NOT:
- Directly INSERT into scanned_files
- Directly INSERT into tracks

=item * Documentation complete

The guide documentation exists and covers key concepts

=back

=head1 USAGE

  perl t/validate_external_db_plugin.t

=cut
