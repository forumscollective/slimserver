# Guide: Creating a Plugin with External Database Source

## Overview

This guide explains how to properly create a Lyrion Music Server plugin that uses an external database (like SQLite) to provide track information instead of scanning the filesystem.

## Common Mistake: Trying to Intercept the Scanner

**WRONG APPROACH:** Attempting to intercept or prevent `scanner.pl` from scanning the filesystem directly. This leads to database corruption because:

1. The scanner manages complex transaction handling and database commits
2. The `scanned_files` table must be properly populated
3. Database integrity depends on proper use of AutoCommit=0 mode
4. Multiple temporary tables are created and managed during scanning

## Correct Approach: Using the Importer Interface

The correct way is to implement an **Importer** that works WITH the scanner, not against it.

### Key Principles

1. **Use the Importer Interface**: Register your importer using `Slim::Music::Import->addImporter()`
2. **Let LMS Handle Transactions**: Don't manipulate database commits directly
3. **Use `updateOrCreate`**: This method handles all the complexity of track management
4. **Don't Bypass File Scanning**: If you need to prevent actual file I/O, you have two options:
   - Configure LMS to use specific folders that don't require scanning
   - Or implement a complete importer like iTunes that provides ALL track data

### Implementation Pattern

```perl
package Slim::Plugin::YourPlugin::Importer;

use strict;
use base qw(Slim::Plugin::Base);

use DBI;
use Slim::Music::Import;
use Slim::Schema;
use Slim::Utils::Log;
use Slim::Utils::Progress;

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.yourplugin',
    'defaultLevel' => 'ERROR',
    'logGroups'    => 'SCANNER',
});

my $prefs = preferences('plugin.yourplugin');

# Initialize the importer
sub initPlugin {
    my $class = shift;
    
    Slim::Music::Import->addImporter($class, {
        'type'         => 'file',      # Type of importer
        'weight'       => 20,           # Priority (lower runs first)
        'reset'        => \&resetState, # Called on wipe
        'playlistOnly' => 0,            # Set to 1 if only playlists
        'use'          => $prefs->get('enabled'), # Whether to use this importer
    });
    
    return 1;
}

# Reset state when database is wiped
sub resetState {
    $log->info("Database wiped - resetting state");
    Slim::Music::Import->setLastScanTime('YourPlugin_LastScan', -1);
}

# Main scanning method
sub startScan {
    my $class = shift;
    
    return 0 unless $prefs->get('enabled');
    
    $log->error("Starting YourPlugin import");
    
    # Connect to your external database
    my $alib_dbh = DBI->connect(
        "dbi:SQLite:dbname=" . $prefs->get('database_path'),
        "", "",
        { RaiseError => 1, AutoCommit => 1 }
    );
    
    # Get track count for progress bar
    my ($count) = $alib_dbh->selectrow_array("SELECT COUNT(*) FROM alib");
    
    my $progress = Slim::Utils::Progress->new({
        'type'  => 'importer',
        'name'  => 'yourplugin',
        'total' => $count,
        'bar'   => 1
    });
    
    # Query your external database
    my $sth = $alib_dbh->prepare("
        SELECT 
            file_path, title, artist, album, genre,
            track_number, year, duration, bitrate, filesize,
            modified_time
        FROM alib
        ORDER BY file_path
    ");
    
    $sth->execute();
    
    my $changes = 0;
    my $lastCommit = time();
    
    while (my $row = $sth->fetchrow_hashref()) {
        $progress->update();
        
        # Convert file path to URL
        my $url = Slim::Utils::Misc::fileURLFromPath($row->{file_path});
        
        # Prepare metadata attributes
        my %attributes = (
            'TITLE'     => $row->{title},
            'ARTIST'    => $row->{artist},
            'ALBUM'     => $row->{album},
            'GENRE'     => $row->{genre},
            'TRACKNUM'  => $row->{track_number},
            'YEAR'      => $row->{year},
            'SECS'      => $row->{duration},
            'BITRATE'   => $row->{bitrate},
            'FS'        => $row->{filesize},
            'TIMESTAMP' => $row->{modified_time},
            'AUDIO'     => 1,
        );
        
        # Use updateOrCreate to add/update the track
        # This is THE CORRECT WAY - it handles everything:
        # - Checking if file exists
        # - Updating scanned_files table
        # - Managing track relationships
        # - Handling timestamps and changes
        my $track = Slim::Schema->updateOrCreate({
            'url'        => $url,
            'attributes' => \%attributes,
            'readTags'   => 0,  # Don't read tags from file since we have metadata
            'checkMTime' => 0,  # Don't check file modification time
        });
        
        if ($track) {
            $changes++;
        }
        
        # Commit periodically (every 5 seconds like iTunes importer)
        if (time() > $lastCommit + 5) {
            Slim::Schema->forceCommit;
            $lastCommit = time();
        }
        
        # Check if scan was aborted
        if (Slim::Music::Import->hasAborted()) {
            $log->warn("Import aborted by user");
            last;
        }
    }
    
    $sth->finish();
    $alib_dbh->disconnect();
    
    $progress->final();
    
    $log->error("Finished importing $changes tracks from external database");
    
    # Record scan completion time
    Slim::Music::Import->setLastScanTime('YourPlugin_LastScan', time());
    
    # Tell the import manager we're done
    Slim::Music::Import->endImporter($class);
    
    return $changes;
}

1;
```

### Plugin Main File

```perl
package Slim::Plugin::YourPlugin::Plugin;

use strict;
use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Music::Import;

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.yourplugin',
    'defaultLevel' => 'ERROR',
});

my $prefs = preferences('plugin.yourplugin');

$prefs->init({
    enabled       => 0,
    database_path => '',
});

sub initPlugin {
    my $class = shift;
    
    # Load the importer
    require Slim::Plugin::YourPlugin::Importer;
    Slim::Plugin::YourPlugin::Importer->initPlugin();
    
    $class->SUPER::initPlugin(@_);
}

# When plugin is enabled/disabled
$prefs->setChange(
    sub {
        my $value = $_[1];
        Slim::Music::Import->useImporter('Slim::Plugin::YourPlugin::Importer', $value);
        
        # Trigger rescan when enabled
        if ($value) {
            Slim::Control::Request::executeRequest(undef, ['rescan']);
        }
    },
    'enabled'
);

sub getDisplayName { 'PLUGIN_YOURPLUGIN' }

1;
```

## Why This Approach Works

1. **No Database Corruption**: You're using the official API that handles all database integrity
2. **Proper Transaction Management**: `Slim::Schema->forceCommit` is called at appropriate times
3. **Correct scanned_files Handling**: The `updateOrCreate` method populates this table correctly
4. **Change Detection**: The system can detect when tracks are added/removed/changed
5. **Progress Reporting**: Users see proper progress during import
6. **Integration**: Works with all other LMS features (web UI, playlists, etc.)

## What updateOrCreate Does

The `Slim::Schema->updateOrCreate()` method (defined in `Slim/Schema.pm`) handles:

1. Converting the file path to a URL
2. Checking if the track already exists in the database
3. Comparing timestamps to detect changes
4. Inserting into `scanned_files` table with proper timestamp and filesize
5. Creating/updating the track in the `tracks` table
6. Managing all relationships (artists, albums, genres, contributors)
7. Handling virtual tracks (cue sheets, etc.)
8. Optionally reading tags from the file if requested
9. Returning a Track object or undef if it fails

## Common Pitfalls to Avoid

### ❌ DON'T: Directly manipulate scanned_files

```perl
# WRONG - causes corruption
$dbh->do("INSERT INTO scanned_files (url, timestamp, filesize) VALUES (?, ?, ?)", 
         undef, $url, $mtime, $size);
```

### ✅ DO: Use updateOrCreate

```perl
# CORRECT
Slim::Schema->updateOrCreate({
    'url'        => $url,
    'attributes' => \%metadata,
});
```

### ❌ DON'T: Try to prevent filesystem scanning

```perl
# WRONG - trying to hook into file finding
Slim::Utils::Scanner::Local->find = sub { ... };
```

### ✅ DO: Let the importer provide the data

```perl
# CORRECT - provide data through importer interface
sub startScan {
    # Read from your database and call updateOrCreate for each track
}
```

### ❌ DON'T: Manage transactions yourself

```perl
# WRONG
$dbh->begin_work;
# ... operations ...
$dbh->commit;
```

### ✅ DO: Use forceCommit periodically

```perl
# CORRECT
Slim::Schema->forceCommit;
```

## Advanced: Preventing Filesystem Access

If your goal is to COMPLETELY avoid filesystem access (not even checking if files exist), you need to:

1. **Set readTags => 0 and checkMTime => 0** in updateOrCreate
2. **Provide complete metadata** from your database
3. **Ensure files actually exist** at the paths you provide, or use virtual URLs
4. **Handle the entire library** through your importer

However, note that:
- The scanner will still populate `scanned_files` through your importer
- Some features may expect actual file access (like artwork extraction)
- It's often better to let LMS do minimal file checks for consistency

## Testing Your Plugin

1. **Start with a small dataset** (10-20 tracks)
2. **Enable debug logging** for your plugin and scanner
3. **Watch for errors** in scanner.log
4. **Verify database integrity** by checking:
   - Track counts match your external database
   - Metadata displays correctly in the UI
   - Playlists work
   - No corruption errors in logs

5. **Test rescan scenarios**:
   - Full rescan
   - Wipe and rescan
   - Incremental updates (if supported)

## Summary

The key to avoiding database corruption is to **work with LMS's architecture, not against it**. Use the Importer interface and `updateOrCreate()` method, and let LMS handle the complex database management. This ensures your external database integrates cleanly without causing corruption.
