package Slim::Plugin::ExternalDB::Importer;

# Example importer showing the CORRECT pattern for external database integration
# This demonstrates how to import tracks from an external SQLite database
# without causing database corruption in Lyrion Music Server.

use strict;
use base qw(Slim::Plugin::Base);

use DBI;
use File::Spec::Functions qw(catfile);
use Slim::Music::Import;
use Slim::Schema;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Utils::Progress;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.externaldb',
	'defaultLevel' => 'WARN',
});

my $prefs = preferences('plugin.externaldb');

# Track whether we've initialized
my $initialized = 0;

sub initPlugin {
	my $class = shift;
	
	return 1 if $initialized;
	
	$log->info("Registering External Database Importer");
	
	# Register this importer with the LMS import system
	# This is THE CORRECT WAY to integrate an external data source
	Slim::Music::Import->addImporter($class, {
		'type'         => 'file',           # Type of content we import
		'weight'       => 20,                # Priority (lower numbers run first)
		'reset'        => \&resetState,      # Called when database is wiped
		'playlistOnly' => 0,                 # Set to 1 if only importing playlists
		'use'          => $prefs->get('enabled'), # Whether to use this importer
	});
	
	$initialized = 1;
	return 1;
}

# Called when the database is wiped (--wipe flag)
sub resetState {
	$log->info("Database wiped - resetting External DB import state");
	
	# Reset our tracking of last scan
	Slim::Music::Import->setLastScanTime('ExternalDB_LastScan', -1);
}

# Main scanning method - called by scanner.pl
# This is where we read from the external database and import tracks
sub startScan {
	my $class = shift;
	
	# Don't run if plugin is disabled
	return 0 unless $prefs->get('enabled');
	
	my $db_path = $prefs->get('database_path');
	
	if (!$db_path || !-f $db_path) {
		$log->error("External database not found at: " . ($db_path || 'not configured'));
		return 0;
	}
	
	$log->error("Starting External Database import from: $db_path");
	
	# Connect to the external database
	# NOTE: This is a SEPARATE database from LMS's library.db
	my $ext_dbh = eval {
		DBI->connect(
			"dbi:SQLite:dbname=$db_path",
			"", "",
			{
				RaiseError => 1,
				PrintError => 0,
				AutoCommit => 1,  # External DB can use autocommit
				sqlite_unicode => 1,
			}
		);
	};
	
	if (!$ext_dbh || $@) {
		$log->error("Failed to connect to external database: " . ($@ || $DBI::errstr));
		return 0;
	}
	
	# Get total count for progress bar
	my ($total_count) = eval {
		$ext_dbh->selectrow_array("SELECT COUNT(*) FROM alib");
	};
	
	if ($@ || !defined $total_count) {
		$log->error("Failed to count tracks in external database: " . ($@ || $DBI::errstr));
		$ext_dbh->disconnect();
		return 0;
	}
	
	$log->error("Found $total_count tracks in external database");
	
	# Create progress tracker for the UI
	my $progress = Slim::Utils::Progress->new({
		'type'  => 'importer',
		'name'  => 'externaldb',
		'total' => $total_count,
		'bar'   => 1
	});
	
	# Prepare query to read tracks from external database
	# Adjust this query to match your actual database schema
	my $sth = eval {
		$ext_dbh->prepare(qq{
			SELECT 
				file_path,
				title,
				artist,
				album,
				genre,
				track_number,
				disc_number,
				year,
				duration_seconds,
				bitrate,
				filesize,
				modified_time,
				comment,
				album_artist,
				composer
			FROM alib
			WHERE file_path IS NOT NULL
			ORDER BY file_path
		});
	};
	
	if (!$sth || $@) {
		$log->error("Failed to prepare query: " . ($@ || $DBI::errstr));
		$ext_dbh->disconnect();
		return 0;
	}
	
	eval { $sth->execute(); };
	
	if ($@) {
		$log->error("Failed to execute query: $@");
		$ext_dbh->disconnect();
		return 0;
	}
	
	my $changes = 0;
	my $skipped = 0;
	my $errors = 0;
	my $lastCommit = time();
	
	# Process each track from external database
	while (my $row = eval { $sth->fetchrow_hashref() }) {
		
		# Update progress for UI
		$progress->update();
		
		# Skip if aborted
		if (Slim::Music::Import->hasAborted()) {
			$log->warn("Import aborted by user");
			last;
		}
		
		my $file_path = $row->{file_path};
		
		# Skip if no file path
		if (!$file_path) {
			$skipped++;
			next;
		}
		
		# Convert file path to URL format expected by LMS
		# This is CRITICAL - LMS uses URLs internally, not file paths
		my $url = Slim::Utils::Misc::fileURLFromPath($file_path);
		
		# Build metadata attributes from external database
		# Only include defined values
		my %attributes;
		
		$attributes{'TITLE'}     = $row->{title}            if defined $row->{title};
		$attributes{'ARTIST'}    = $row->{artist}           if defined $row->{artist};
		$attributes{'ALBUM'}     = $row->{album}            if defined $row->{album};
		$attributes{'GENRE'}     = $row->{genre}            if defined $row->{genre};
		$attributes{'TRACKNUM'}  = $row->{track_number}     if defined $row->{track_number};
		$attributes{'DISC'}      = $row->{disc_number}      if defined $row->{disc_number};
		$attributes{'YEAR'}      = $row->{year}             if defined $row->{year};
		$attributes{'SECS'}      = $row->{duration_seconds} if defined $row->{duration_seconds};
		$attributes{'BITRATE'}   = $row->{bitrate}          if defined $row->{bitrate};
		$attributes{'FS'}        = $row->{filesize}         if defined $row->{filesize};
		$attributes{'TIMESTAMP'} = $row->{modified_time}    if defined $row->{modified_time};
		$attributes{'COMMENT'}   = $row->{comment}          if defined $row->{comment};
		$attributes{'ALBUMARTIST'} = $row->{album_artist}   if defined $row->{album_artist};
		$attributes{'COMPOSER'}  = $row->{composer}         if defined $row->{composer};
		$attributes{'AUDIO'}     = 1;  # Mark as audio content
		
		# THIS IS THE KEY METHOD - updateOrCreate does EVERYTHING correctly:
		# 1. Checks if track already exists
		# 2. Updates scanned_files table with proper timestamp/size
		# 3. Creates/updates the track in tracks table
		# 4. Manages all relationships (artists, albums, genres, contributors)
		# 5. Handles change detection
		# 6. Respects the scanner's transaction management
		# 
		# Parameters:
		#   url        - The file URL (required)
		#   attributes - Metadata hash (title, artist, etc.)
		#   readTags   - Whether to read tags from the actual file
		#                Set to 0 since we have metadata from external DB
		#   checkMTime - Whether to check file modification time
		#                Set to 0 if you trust your external DB timestamps
		my $track = eval {
			Slim::Schema->updateOrCreate({
				'url'        => $url,
				'attributes' => \%attributes,
				'readTags'   => 0,  # Don't read tags - we have metadata
				'checkMTime' => 0,  # Don't check mtime - we have timestamp
			});
		};
		
		if ($@) {
			$log->warn("Error importing track $url: $@");
			$errors++;
			next;
		}
		
		if ($track) {
			$changes++;
			
			main::DEBUGLOG && $log->is_debug && $log->debug(
				"Imported: " . ($attributes{'TITLE'} || 'Unknown') . 
				" by " . ($attributes{'ARTIST'} || 'Unknown')
			);
		} else {
			$skipped++;
		}
		
		# Commit periodically to avoid huge transactions
		# This pattern is taken from the iTunes importer
		# Commit every 5 seconds of processing
		if (time() > $lastCommit + 5) {
			main::SCANNER && Slim::Schema->forceCommit;
			$lastCommit = time();
		}
	}
	
	if ($@) {
		$log->error("Error during track fetch: $@");
	}
	
	# Clean up
	eval {
		$sth->finish();
		$ext_dbh->disconnect();
	};
	
	# Finalize progress
	$progress->final();
	
	$log->error(sprintf(
		"External DB import complete: %d imported, %d skipped, %d errors",
		$changes, $skipped, $errors
	));
	
	# Record when we last scanned
	Slim::Music::Import->setLastScanTime('ExternalDB_LastScan', time());
	
	# Tell the import manager we're done
	Slim::Music::Import->endImporter($class);
	
	# Return number of changes made
	return $changes;
}

1;

__END__

=head1 NAME

Slim::Plugin::ExternalDB::Importer

=head1 DESCRIPTION

This module demonstrates the CORRECT pattern for importing music metadata from
an external database into Lyrion Music Server without causing database corruption.

=head1 KEY CONCEPTS

=head2 Why This Approach Works

1. B<Uses the Importer Interface>: Registered via addImporter(), so LMS knows
   about it and can manage it properly.

2. B<Uses updateOrCreate()>: This is THE critical method. It handles:
   - Populating scanned_files table correctly
   - Creating/updating tracks with proper relationships
   - Managing database transactions appropriately
   - Change detection and incremental updates

3. B<Respects Transaction Management>: We call forceCommit() periodically
   but let LMS manage AutoCommit=0 mode and overall transaction flow.

4. B<Works WITH the Scanner>: We don't try to intercept or prevent the scanner.
   We provide data through the official interface.

=head2 What NOT To Do

DO NOT try to:
- Directly INSERT into scanned_files table
- Directly INSERT/UPDATE tracks table
- Manage database transactions yourself (BEGIN/COMMIT)
- Intercept or hook scanner.pl file finding
- Modify Scanner::Local::find() or similar methods
- Set AutoCommit on the main database handle

These approaches WILL cause database corruption.

=head2 Database Schema for External DB

Your external database should have a table like:

  CREATE TABLE alib (
    file_path TEXT PRIMARY KEY,
    title TEXT,
    artist TEXT,
    album TEXT,
    genre TEXT,
    track_number INTEGER,
    disc_number INTEGER,
    year INTEGER,
    duration_seconds REAL,
    bitrate INTEGER,
    filesize INTEGER,
    modified_time INTEGER,
    comment TEXT,
    album_artist TEXT,
    composer TEXT
  );

Adjust the query in startScan() to match your actual schema.

=head1 TESTING

Test your implementation with:

1. Small dataset first (10-20 tracks)
2. Enable debug logging: server.log and scanner.log
3. Run: scanner.pl --rescan --debug plugin.externaldb=debug
4. Check for errors in logs
5. Verify tracks appear in UI with correct metadata
6. Test wipe: scanner.pl --wipe --rescan
7. Test incremental updates

=head1 SEE ALSO

L<Slim::Plugin::iTunes::Importer> - Production example
L<Slim::Schema> - updateOrCreate documentation
L<Slim::Music::Import> - Import system

=cut
