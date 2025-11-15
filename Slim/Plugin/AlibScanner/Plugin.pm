package Slim::Plugin::AlibScanner::Plugin;

use strict;
use base qw(Slim::Plugin::Base);

if ( main::WEBUI ) {
    require Slim::Plugin::AlibScanner::Settings;
}

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log = logger('plugin.alibscanner');
my $prefs = preferences('plugin.alibscanner');

# Default preferences
$prefs->init({
    alibdb => '',
    enabled => 0,
});

sub initPlugin {
    my $class = shift;

    warn "AlibScanner::initPlugin() called, SCANNER=" . (main::SCANNER ? 'YES' : 'NO') . "\n";

    $class->SUPER::initPlugin(@_);

    if ( main::WEBUI ) {
        Slim::Plugin::AlibScanner::Settings->new;
    }

    # Call init regardless of whether we're in scanner or server
    $class->init();
}

sub init {
    my $class = shift;
    
    my $enabled = $prefs->get('enabled');
    my $alibdb = $prefs->get('alibdb');

    warn "AlibScanner::init() called, SCANNER=" . (main::SCANNER ? 'YES' : 'NO') . ", enabled=$enabled, alibdb=$alibdb\n";

    $log->info("AlibScanner init() - enabled=$enabled, alibdb=$alibdb");

    # Register our importer in both server and scanner processes
    if ($enabled && $alibdb) {
        warn "AlibScanner: Registering importer\n";
        require Slim::Plugin::AlibScanner::Importer;
        
        # Register our importer to run BEFORE MediaFolderScan (weight 0 < 1)
        Slim::Music::Import->addImporter('Slim::Plugin::AlibScanner::Importer', {
            type   => 'file',
            weight => 0,   # Run BEFORE MediaFolderScan (weight 1)
            use    => 1,
        });
        
        $log->info("AlibScanner importer registered with alib database: $alibdb");
        
        # CRITICAL: Disable MediaFolderScan so it doesn't run after us
        # Our plugin handles all the scanning via alib
        warn "AlibScanner: Disabling MediaFolderScan\n";
        Slim::Music::Import->useImporter('Slim::Media::MediaFolderScan', 0);
        
        $log->info("MediaFolderScan disabled - AlibScanner will handle all scanning");
    }
    else {
        warn "AlibScanner: NOT registering importer (enabled=$enabled, alibdb=$alibdb)\n";
    }
}

sub getDisplayName {
    return 'PLUGIN_ALIBSCANNER';
}

sub enabled {
    return $prefs->get('enabled');
}

1;
