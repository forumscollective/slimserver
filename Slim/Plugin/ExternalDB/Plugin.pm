package Slim::Plugin::ExternalDB::Plugin;

# Example plugin showing how to properly integrate an external database
# This is a REFERENCE IMPLEMENTATION demonstrating the correct pattern
# to avoid database corruption when importing from external sources.

use strict;
use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Music::Import;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.externaldb',
	'defaultLevel' => 'WARN',
	'description'  => 'External Database Import Example',
	'logGroups'    => 'SCANNER',
});

my $prefs = preferences('plugin.externaldb');

# Initialize preferences with defaults
$prefs->init({
	enabled       => 0,
	database_path => '',
});

sub initPlugin {
	my $class = shift;
	
	$log->info("Initializing External Database Plugin");
	
	# Load the importer module
	require Slim::Plugin::ExternalDB::Importer;
	Slim::Plugin::ExternalDB::Importer->initPlugin();
	
	$class->SUPER::initPlugin(@_);
}

# Handle plugin enable/disable
$prefs->setChange(
	sub {
		my $value = $_[1];
		
		$log->info("External DB plugin " . ($value ? "enabled" : "disabled"));
		
		# Tell the import system whether to use this importer
		Slim::Music::Import->useImporter('Slim::Plugin::ExternalDB::Importer', $value);
		
		# Trigger a rescan when enabled to import tracks
		if ($value) {
			Slim::Control::Request::executeRequest(undef, ['rescan']);
		}
	},
	'enabled'
);

# Handle database path changes
$prefs->setChange(
	sub {
		my $path = $_[1];
		
		if ($path && -f $path) {
			$log->info("External database path updated to: $path");
			
			# Rescan if plugin is enabled
			if ($prefs->get('enabled')) {
				Slim::Control::Request::executeRequest(undef, ['rescan']);
			}
		}
	},
	'database_path'
);

sub getDisplayName {
	return 'PLUGIN_EXTERNALDB';
}

sub enabled {
	return $prefs->get('enabled');
}

1;

__END__

=head1 NAME

Slim::Plugin::ExternalDB::Plugin

=head1 DESCRIPTION

This is a reference implementation plugin that demonstrates the CORRECT way to
integrate an external database (like SQLite) with Lyrion Music Server without
causing database corruption.

KEY PRINCIPLES:

1. Use the Importer interface - don't try to intercept the scanner
2. Use Slim::Schema->updateOrCreate() - don't manipulate tables directly
3. Let LMS handle transactions - use forceCommit() at appropriate times
4. Work WITH the scanner, not against it

This plugin is disabled by default and serves as a template for developers
building similar functionality.

=head1 USAGE

To use this as a template:

1. Copy this plugin directory to your own plugin
2. Rename the package and files
3. Implement your external database logic in Importer.pm
4. Configure the database path in plugin preferences

=head1 SEE ALSO

L<Slim::Plugin::iTunes::Importer> - Real-world example of external import
L<Slim::Music::Import> - Import system documentation
L<Slim::Schema> - Database schema and updateOrCreate method

=cut
