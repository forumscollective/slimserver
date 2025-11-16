package Slim::Plugin::AlibScanner::Plugin;

use strict;
use base qw(Slim::Plugin::Base);

if ( main::WEBUI ) {
    require Slim::Plugin::AlibScanner::Settings;
}

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Music::Import;

my $log = logger('plugin.alibscanner');
my $prefs = preferences('plugin.alibscanner');

# Default preferences
$prefs->init({
    alibdb => '',
    enabled => 0,
    debugPlaceholders => 0, # instrumentation toggle for contributor anomalies
    debugPlaceholdersVerbose => 0, # high-volume diagnostic traces
    anomalyChecksEnabled => 0, # baseline anomaly checks disabled by default
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
        # Ensure native scanner is active when plugin disabled at startup
        _restoreNativeScanner();
    }

    # Watch preference changes for dynamic enable/disable
    $prefs->setChange( sub {
        my ($pref, $newVal) = @_;
        return unless $pref eq 'enabled';
        my $context = main::SCANNER ? 'SCANNER' : 'SERVER';
        $log->info("AlibScanner pref flip: enabled => $newVal ($context)");
        if ($newVal) {
            $log->info('AlibScanner enabling: registering importer and disabling MediaFolderScan');
            $class->init();
        } else {
            $log->info('AlibScanner disabling: restoring native scanner & removing hooks');
            _disableAlibScanner();
        }
    }, 'enabled');
}

sub getDisplayName {
    return 'PLUGIN_ALIBSCANNER';
}

sub enabled {
    return $prefs->get('enabled');
}

sub _disableAlibScanner {
    # Mark our importer unused
    if (Slim::Music::Import->importers->{'Slim::Plugin::AlibScanner::Importer'}) {
        Slim::Music::Import->useImporter('Slim::Plugin::AlibScanner::Importer', 0);
    }
    # Attempt to remove hooks if still present (safe to call even if not installed)
    eval {
        require Slim::Plugin::AlibScanner::Importer;
        Slim::Plugin::AlibScanner::Importer::_removeHooks();
    };
    if ($@) {
        $log->warn("AlibScanner: failed to remove hooks on disable: $@");
    }
    _restoreNativeScanner();
    $log->info('AlibScanner disabled: native scanning restored');
}

sub _restoreNativeScanner {
    # Re-add MediaFolderScan if it was deleted entirely
    require Slim::Media::MediaFolderScan;
    my $importers = Slim::Music::Import->importers;
    if (!exists $importers->{'Slim::Media::MediaFolderScan'}) {
        Slim::Media::MediaFolderScan::init();
        $log->info('AlibScanner: MediaFolderScan re-added');
    } else {
        # Ensure it's enabled
        Slim::Music::Import->useImporter('Slim::Media::MediaFolderScan', 1);
    }
}

1;
