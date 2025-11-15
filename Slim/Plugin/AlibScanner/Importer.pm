package Slim::Plugin::AlibScanner::Importer;

# Lyrion Music Server Copyright 2025 Lyrion Community.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, version 2.

use strict;
use base qw(Slim::Music::Import);

use DBI;
use Digest::MD5 qw(md5_hex);
use File::Spec::Functions qw(:ALL);

use Slim::Music::Info;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Utils::Scanner;
use Slim::Schema;
use Slim::Formats;
use Slim::Utils::Progress;

my $log = logger('plugin.alibscanner');
my $prefs = preferences('plugin.alibscanner');

# Cache for alib database handle and data
my $alibDbh;
my $alibCache = {};

# Track whether hooks are installed
my $hooksInstalled = 0;
my ($orig_AudioScan_scan, $orig_readTags, $orig_pathFromFileURL);

# This is called by the scanner process when it loads import modules
sub initPlugin {
    my $class = shift;
    
    my $enabled = $prefs->get('enabled');
    my $alibdb = $prefs->get('alibdb');
    
    warn "AlibScanner::Importer::initPlugin() called, enabled=$enabled, alibdb=$alibdb\n";
    
    if ($enabled && $alibdb && -f $alibdb) {
        # Install hooks IMMEDIATELY, before any scanning happens
        _installHooks();
        
        # CRITICAL: Remove MediaFolderScan completely so no filesystem scanning occurs
        Slim::Music::Import->deleteImporter('Slim::Media::MediaFolderScan');
        
        # Register ourselves as a 'post' type importer
        # This runs after file scanning would have happened (but we've disabled it)
        Slim::Music::Import->addImporter($class, {
            type   => 'post',
            weight => 1,
            use    => 1,
        });
        
        warn "AlibScanner::Importer registered and MediaFolderScan deleted\n";
    }
}

sub startScan {
    my $class = shift;

    warn "DEBUG: startScan() called\n";
    $log->error("=== AlibScanner::startScan() called ===");

    my $alibPath = $prefs->get('alibdb');

    if (!$alibPath || !-f $alibPath) {
        $log->error("alib database not found at: $alibPath");
        Slim::Music::Import->endImporter($class);
        return 0;
    }

    # Signature-based short-circuit: if alib file unchanged, skip heavy ingestion
    my @stat = stat($alibPath);
    if (@stat) {
        my ($size, $mtime) = ($stat[7], $stat[9]);
        my $sig = "$size:$mtime";
        my $lastSig = $prefs->get('lastAlibSig');
        if (defined $lastSig && $lastSig eq $sig) {
            $log->info("AlibScanner: alib signature unchanged ($sig) - skipping ingestion pass");
            # Hooks not needed if we don't ingest; restore native immediately
            _removeHooks();
            Slim::Music::Import->endImporter($class);
            return 0;
        }
        else {
            $log->info("AlibScanner: alib signature changed or first run (prev=" . (defined $lastSig ? $lastSig : 'undef') . ", new=$sig) - performing ingestion");
            $prefs->set('lastAlibSig', $sig);
        }
    }

    $log->error("Starting alib scan from: $alibPath");

    # Connect to alib database
    eval {
        $alibDbh = DBI->connect(
            "dbi:SQLite:dbname=$alibPath",
            "", "",
            {
                RaiseError => 1,
                AutoCommit => 1,
                sqlite_unicode => 1,
            }
        ) or die "Cannot open alib database: $DBI::errstr";
    };

    if ($@) {
        $log->error("Failed to connect to alib database: $@");
        Slim::Music::Import->endImporter($class);
        return 0;
    }

    $log->error("Loading alib metadata into cache...");
    _loadAlibCache();
    warn "DEBUG: After _loadAlibCache(), cache has " . scalar(keys %$alibCache) . " entries\n";
    # Additional verification: compare raw DB row count to cache key count
    my ($dbCount) = $alibDbh->selectrow_array("SELECT COUNT(*) FROM alib");
    $log->error("Loaded " . scalar(keys %$alibCache) . " tracks from alib (DB rows=$dbCount)");
    $log->error("DEBUG: cacheKeyCount=" . scalar(keys %$alibCache));

    # Process all tracks from alib
    $log->error("Processing tracks from alib...");
    my $changes = _processAllTracks();
    $log->error("AlibScanner processed $changes tracks");

    # Restore default scanner behaviour before other importers (artwork, artist images) run
    _removeHooks();

    # Cleanup
    if ($alibDbh) {
        $alibDbh->disconnect();
        $alibDbh = undef;
    }
    # Keep cache until hooks removed; now safe to free
    $alibCache = {};

    Slim::Music::Import->endImporter($class);
    
    return $changes;
}

sub _loadAlibCache {
    $log->error("DEBUG: _loadAlibCache() called");
    my $sth = $alibDbh->prepare("SELECT * FROM alib");
    $sth->execute();

    my $dbRows = 0;
    my $cacheEntries = 0;
    my %seen;
    my $dupeUrl = 0;
    my %lcCount;          # track lower-case collisions for reporting
    my %lcExamples;       # store up to 3 examples per lower-case key

    while (my $row = $sth->fetchrow_hashref) {
        $dbRows++;
        my $path = $row->{__path} or next;

        # Produce canonical LMS URL with original case preserved
        my $url = Slim::Utils::Misc::fixPath($path);
        $dupeUrl++ if $seen{$url}++;
        $alibCache->{$url} = $row;
        $cacheEntries++;

        # Lower-case duplicate tracking (diagnostic only)
        my $lc = lc $url;
        $lcCount{$lc}++;
        if ($lcCount{$lc} <= 3) { push @{ $lcExamples{$lc} }, $url; }
    }

    $sth->finish();

    my $finalCacheKeys = scalar(keys %$alibCache);
    $log->error("DEBUG: DB rows=$dbRows, inserted=$cacheEntries, duplicate URL hits=$dupeUrl, final cache keys=$finalCacheKeys");

    # Report lower-case collisions to help user clean filesystem (only if any)
    my @lcDupes = grep { $lcCount{$_} > 1 } keys %lcCount;
    if (@lcDupes) {
        my $reported = 0;
        $log->error("DEBUG: lower-case duplicate groups=" . scalar(@lcDupes));
        for my $k (sort { $lcCount{$b} <=> $lcCount{$a} } @lcDupes) {
            last if $reported >= 10; # cap output
            my $examples = join(' | ', @{ $lcExamples{$k} });
            $log->error("DUPLCASE group size=$lcCount{$k} sample=$examples");
            $reported++;
        }
        $log->error("DEBUG: (showing up to 10 groups, max 3 examples each)");
    }
}

sub _processAllTracks {
    my $changes = 0;

    # Get all URLs from the cache we already loaded
    my @urls = keys %$alibCache;
    my $total = scalar @urls;

    # Classify URLs into new vs changed for separate progress bars
    my %existing;
    {
        my $dbh = Slim::Schema->dbh;
        my $sth = $dbh->prepare('SELECT url FROM tracks');
        eval { $sth->execute(); };
        if ($@) {
            $log->warn("AlibScanner: failed to preload existing URLs: $@");
        }
        else {
            while (my ($eurl) = $sth->fetchrow_array) { $existing{$eurl} = 1; }
            $sth->finish;
            $log->info('AlibScanner: preloaded existing track URL hash size=' . scalar(keys %existing));
        }

        # Preload existing composer contributor sets to detect removals or changes not flagged by sqlmodded
        my $compSTH = $dbh->prepare(q{
            SELECT t.url, GROUP_CONCAT(c.name, '\x1F') AS composers
            FROM tracks t
            JOIN contributor_track ct ON t.id = ct.track AND ct.role = 2
            JOIN contributors c ON ct.contributor = c.id
            GROUP BY t.url
        });
        eval { $compSTH->execute(); };
        if ($@) {
            $log->warn("AlibScanner: failed to preload composer sets: $@");
        }
        else {
            while (my ($curl, $names) = $compSTH->fetchrow_array) {
                $existing{"_COMPOSERS_$curl"} = $names; # store separately with prefix key
            }
            $compSTH->finish;
        }
    }

    my (@newUrls, @changedUrls);
    for my $url (@urls) {
        my $row = $alibCache->{$url};
        if (!$existing{$url}) {
            push @newUrls, $url;
        }
        else {
            my $markedChanged;
            if ($row && defined $row->{sqlmodded} && $row->{sqlmodded} > 0) {
                $markedChanged = 1;
            }
            # Detect composer set differences even if sqlmodded not flagged
            my $dbComposerSet = $existing{"_COMPOSERS_$url"};
            my $alibComposerRaw = $row->{composer};
            my @alibComposers;
            if (defined $alibComposerRaw && length $alibComposerRaw) {
                @alibComposers = grep { length $_ } map { my $v = $_; $v =~ s/^\s+|\s+$//g; $v } split /\\\\/, $alibComposerRaw;
            }
            my @dbComposers = defined $dbComposerSet ? split(/\x1F/, $dbComposerSet) : (); # stored separator
            # Normalize case and sort for comparison
            my $normAlib = join('\x1E', sort map { lc $_ } @alibComposers);
            my $normDb   = join('\x1E', sort map { lc $_ } @dbComposers);
            if (!$markedChanged) {
                if ($normAlib ne $normDb) {
                    $markedChanged = 1;
                    $log->info("AlibScanner: composer delta detected url=$url db=['$normDb'] alib=['$normAlib'] marking changed");
                }
            }
            push @changedUrls, $url if $markedChanged;
        }
    }
    my $newTotal = scalar @newUrls;
    my $changedTotal = scalar @changedUrls;

    # Use native-style progress naming: separate new vs changed vs deleted
    my $alibPath = $prefs->get('alibdb') || 'alib';
    my $progressNew = Slim::Utils::Progress->new({
        type  => 'importer',
        name  => $alibPath . '|directory_new',
        total => $newTotal,
        bar   => 1,
    });
    my $progressChanged;
    if ($changedTotal) {
        $progressChanged = Slim::Utils::Progress->new({
            type  => 'importer',
            name  => $alibPath . '|directory_changed',
            total => $changedTotal,
            bar   => 1,
        });
    }
    
    $log->error("Found $total tracks in alib (new=$newTotal changed=$changedTotal) to process");
    
    # Process each track
    my $count = 0;          # number of new tracks added
    my $updated = 0;        # number of existing tracks whose metadata was updated (sqlmodded)
    my $processedNew = 0;   # progress counter for new tracks
    my $processedChanged = 0; # progress counter for changed tracks
    my %albumSeen;       # distinct album ids
    my $albumSamplesLogged = 0;
    # Process new tracks first
    for my $url (@newUrls) {
        my $row = $alibCache->{$url};
        if (!$existing{$url}) { # always true here, defensive
            # Create new track using our hook for metadata (no filesystem access)
            eval {
                my $trackId = Slim::Schema->updateOrCreateBase({
                    url        => $url,
                    readTags   => 1,      # Use our hook, not filesystem
                    new        => 1,       # This is a new track
                    checkMTime => 0,       # Don't check filesystem mtime
                    commit     => 0,       # Don't commit yet - let scanner control this
                });
                
                if ($trackId) {
                    $changes++;
                    $count++;
                    $processedNew++;
                    # Fetch album id for diagnosis
                    my $dbh2 = Slim::Schema->dbh;
                    my ($albumId) = $dbh2->selectrow_array("SELECT album FROM tracks WHERE id=?", undef, $trackId);
                    if (defined $albumId && $albumId) {
                        $albumSeen{$albumId}++;
                        # Log first few samples
                        if ($albumSamplesLogged < 5) {
                            $log->error("ALBUMTRACE track=$trackId album=$albumId url=$url");
                            $albumSamplesLogged++;
                        }
                    }

                    # Instrumentation: detect placeholder contributor names appearing under wrong roles
                    if ($trackId && $prefs->get('debugPlaceholders')) {
                        my $sthP = $dbh2->prepare(q{
                            SELECT ct.role, c.name FROM contributor_track ct JOIN contributors c ON ct.contributor=c.id WHERE ct.track=?
                        });
                        eval { $sthP->execute($trackId); };
                        if (!$@) {
                            while (my ($r,$n) = $sthP->fetchrow_array) {
                                if ($n =~ /^(ARTIST|ALBUMARTIST|TRACKARTIST|COMPOSER|CONDUCTOR|BAND|PERFORMER|LYRICIST|ARRANGER|ENGINEER|PRODUCER|MIXER|REMIXER)$/i && $r !~ /^[1-6]$/) {
                                    $log->error("PLACEHOLDERTRACE unexpected roleMap track=$trackId url=$url role=$r name=$n");
                                }
                                # Detect cross-role: name equals different role label than numeric role mapping
                                if ($n =~ /^(COMPOSER|CONDUCTOR|LYRICIST|PERFORMER)$/i) {
                                    $log->error("PLACEHOLDERTRACE contributor track=$trackId role=$r name=$n") if $n =~ /^CONDUCTOR$/i && $r != 3;
                                }
                            }
                            $sthP->finish;
                        }
                    }
                }
            };
            
            if ($@) {
                $log->error("Error processing $url: $@");
            }
            
            # Commit every 500 tracks to avoid corruption
            if ($processedNew % 500 == 0) {
                Slim::Schema->forceCommit;
                my $distinctAlbums = scalar keys %albumSeen;
                $log->error("Processed new $processedNew / $newTotal (added=$count) changed=$updated distinctAlbums=$distinctAlbums");
            }
        }
        # Progress update every 500 new tracks
        if ($processedNew % 500 == 0) {
            eval { $progressNew->update($processedNew) };
        }
    }

    # Process changed tracks
    for my $url (@changedUrls) {
        eval {
            my $trackObjOrId = Slim::Schema->updateOrCreateBase({
                url        => $url,
                readTags   => 1,
                checkMTime => 0,
                commit     => 0,
            });
            if ($trackObjOrId) {
                $updated++;
                $processedChanged++;
                if ($prefs->get('debugPlaceholders')) {
                    my $dbh2 = Slim::Schema->dbh;
                    my $idLookup = $dbh2->prepare('SELECT id FROM tracks WHERE url=?');
                    eval { $idLookup->execute($url); };
                    if (!$@) {
                        my ($tid) = $idLookup->fetchrow_array;
                        $idLookup->finish;
                        if ($tid) {
                            my $sthP = $dbh2->prepare(q{
                                SELECT ct.role, c.name FROM contributor_track ct JOIN contributors c ON ct.contributor=c.id WHERE ct.track=?
                            });
                            eval { $sthP->execute($tid); };
                            if (!$@) {
                                while (my ($r,$n) = $sthP->fetchrow_array) {
                                    if ($n =~ /^(CONDUCTOR|LYRICIST|PERFORMER)$/i && $r == 2) { # composer role misuse
                                        $log->error("PLACEHOLDERTRACE updated track id=$tid url=$url composerName=$n role=$r suspect");
                                    }
                                }
                                $sthP->finish;
                            }
                        }
                    }
                }
            }
        };
        if ($@) {
            $log->error("Error updating changed track $url: $@");
        }

        if ($processedChanged % 500 == 0) {
            Slim::Schema->forceCommit;
            my $distinctAlbums = scalar keys %albumSeen;
            $log->error("Processed changed $processedChanged / $changedTotal (added=$count updated=$updated) distinctAlbums=$distinctAlbums");
            eval { $progressChanged && $progressChanged->update($processedChanged) };
        }
    }
    
    # Final commit
    Slim::Schema->forceCommit;
    eval { $progressNew->update($processedNew); $progressNew->final; };
    eval { $progressChanged && $progressChanged->update($processedChanged); $progressChanged && $progressChanged->final; };
    my $finalDistinctAlbums = scalar keys %albumSeen;
    my $processedTotal = $processedNew + $processedChanged;
    $log->error("ALBUMTRACE final distinct album ids=$finalDistinctAlbums (sample logged=$albumSamplesLogged) added=$count updated=$updated totalProcessed=$processedTotal newProcessed=$processedNew changedProcessed=$processedChanged");

    # Deletion pass: remove tracks no longer present in alib
    my @deleted;
    for my $eurl (keys %existing) {
        next if exists $alibCache->{$eurl};
        # only handle local file URLs
        next unless Slim::Music::Info::isFileURL($eurl);
        push @deleted, $eurl;
    }

    my $deletedCount = scalar @deleted;
    if ($deletedCount) {
        $log->error("AlibScanner: found $deletedCount deleted tracks (present in LMS, missing from alib) - removing");
        eval { require Slim::Utils::Scanner::Local; };
        if ($@) {
            $log->error("AlibScanner: failed to load deletion helper Slim::Utils::Scanner::Local: $@");
        }
        else {
            my $delProgressName = ($prefs->get('alibdb') || 'alib') . '|directory_deleted';
            my $delProgress = Slim::Utils::Progress->new({
                type  => 'importer',
                name  => $delProgressName,
                total => $deletedCount,
                bar   => 1,
            });
            my $d = 0;
            for my $url (@deleted) {
                eval { Slim::Utils::Scanner::Local::deleted($url); };
                if ($@) {
                    $log->error("AlibScanner: error deleting $url: $@");
                }
                $d++;
                # update progress every 250 deletions to reduce DB churn
                if ($d % 250 == 0) {
                    eval { $delProgress->update($d); };
                }
            }
            # finalize deletion progress
            eval { $delProgress->update($d); $delProgress->final; };
            Slim::Schema->forceCommit;
            $log->error("AlibScanner: deletion pass complete removed=$d");
            $changes += $deletedCount; # count deletions as changes
        }
    }
    
    return $changes;
}

# Install all necessary hooks to prevent filesystem access
sub _installHooks {
    return if $hooksInstalled;
    
    no warnings 'redefine';

    $log->error("=== AlibScanner: Installing hooks to disable filesystem access ===");

    # Hook 1: Replace Audio::Scan::scan to return alib metadata
    $orig_AudioScan_scan ||= *Audio::Scan::scan{CODE};
    *Audio::Scan::scan = sub {
        my ($class, $file, $opts) = @_;

        # Get from alib - this is the ONLY source
        my $alibData = _getAlibMetadata($file);

        if ($alibData) {
            if (my $tags = $alibData->{tags}) {
                my $url = Slim::Utils::Misc::fixPath($file);
                eval { Slim::Formats::sanitizeTagValues($tags, $url); };
                $log->warn("Error sanitizing tags in scan for $url: $@") if $@;
                for my $mb (grep { /^MUSICBRAINZ.*ID$/ } keys %$tags) {
                    my $val = $tags->{$mb};
                    my $ref = ref $val;
                    my $out = $ref eq 'ARRAY' ? join(',', @$val) : $val;
                    $log->error("MBIDTRACE scan $mb ref=$ref url=$url val=$out") if defined $out;
                }
            }
            return $alibData;
        }

        # Not in alib - return empty to skip this file
        $log->warn("File not found in alib, skipping: $file");
        return {};
    };

    # Hook 2: Override Slim::Formats::readTags to use alib
    $orig_readTags ||= *Slim::Formats::readTags{CODE};
    *Slim::Formats::readTags = sub {
        my ($class, $file) = @_;

        my $url = ref($file) ? $file->url : $file;
        $url = Slim::Utils::Misc::fixPath($url) if $url;

        if ($url && $alibCache->{$url}) {
            my $alibData = _getAlibMetadata($url);
            if ($alibData && $alibData->{tags}) {
                my $tags = $alibData->{tags};
                eval { Slim::Formats::sanitizeTagValues($tags, $url); };
                $log->warn("Error sanitizing tags for $url: $@") if $@;
                for my $mb (grep { /^MUSICBRAINZ.*ID$/ } keys %$tags) {
                    my $val = $tags->{$mb};
                    my $ref = ref $val;
                    my $out = $ref eq 'ARRAY' ? join(',', @$val) : $val;
                    $log->error("MBIDTRACE readTags $mb ref=$ref url=$url val=$out") if defined $out;
                }
                return $tags;
            }
        }

        return {};
    };

    # Hook 3: Make sure pathFromFileURL returns valid paths
    $orig_pathFromFileURL ||= *Slim::Utils::Misc::pathFromFileURL{CODE};
    *Slim::Utils::Misc::pathFromFileURL = sub {
        my ($url, $noCache) = @_;
        return unless defined $url;
        # Avoid expensive backtrace & URI work when given a plain path
        return $url unless $url =~ /^file:\/\//i;
        return $orig_pathFromFileURL->(@_);
    };

    $log->error("All hooks installed - filesystem access disabled");
    $hooksInstalled = 1;
}

sub _removeHooks {
    return unless $hooksInstalled;
    no warnings 'redefine';
    if ($orig_AudioScan_scan) {
        *Audio::Scan::scan = $orig_AudioScan_scan;
    }
    if ($orig_readTags) {
        *Slim::Formats::readTags = $orig_readTags;
    }
    if ($orig_pathFromFileURL) {
        *Slim::Utils::Misc::pathFromFileURL = $orig_pathFromFileURL;
    }
    $hooksInstalled = 0;
    $log->error('AlibScanner: hooks removed, default scanner restored');
}

sub _getAlibMetadata {
    my ($file) = @_;

    # Try both with and without file:// prefix
    my $url = Slim::Utils::Misc::fixPath($file);
    my $alibRow = $alibCache->{$url};

    return unless $alibRow;

    # Convert alib data to Audio::Scan format
    my $tags = {
        # Core metadata
        TITLE       => $alibRow->{title} || $alibRow->{__filename_no_ext} || '',
        ALBUM       => $alibRow->{album} || '',
        TRACKNUM    => $alibRow->{track},
        DISC        => $alibRow->{discnumber} || $alibRow->{disc},
        DISCC       => undef,
        YEAR        => $alibRow->{year} || $alibRow->{originalyear},
        DATE        => $alibRow->{originaldate} || $alibRow->{originalreleasedate},

        # Contributors - handle multi-value fields
        ARTIST      => _splitMultiValue($alibRow->{artist}),
        ALBUMARTIST => _splitMultiValue($alibRow->{albumartist}),
        COMPOSER    => _splitMultiValue($alibRow->{composer}),
        CONDUCTOR   => _splitMultiValue($alibRow->{conductor}),
        LYRICIST    => _splitMultiValue($alibRow->{lyricist} || $alibRow->{writer}),
        ARRANGER    => _splitMultiValue($alibRow->{arranger}),

        # Additional contributors
        BAND        => _splitMultiValue($alibRow->{ensemble}),
        PERFORMER   => _splitMultiValue($alibRow->{performer}),
        ENGINEER    => _splitMultiValue($alibRow->{engineer}),
        PRODUCER    => _splitMultiValue($alibRow->{producer}),
        MIXER       => _splitMultiValue($alibRow->{mixer}),
        REMIXER     => _splitMultiValue($alibRow->{remixer}),

        # Genre
        GENRE       => _splitMultiValue($alibRow->{genre}),
        STYLE       => _splitMultiValue($alibRow->{style}),
        MOOD        => _splitMultiValue($alibRow->{mood}),

        # MusicBrainz IDs - these will be sanitized by LMS
        MUSICBRAINZ_TRACK_ID        => $alibRow->{musicbrainz_trackid},
        MUSICBRAINZ_ALBUM_ID        => $alibRow->{musicbrainz_albumid},
        # Pass raw multi-value MusicBrainz fields (sanitizer will split & validate)
        MUSICBRAINZ_ARTIST_ID       => $alibRow->{musicbrainz_artistid},
        MUSICBRAINZ_ALBUM_ARTIST_ID => $alibRow->{musicbrainz_albumartistid},
        MUSICBRAINZ_RELEASE_GROUP_ID => $alibRow->{musicbrainz_releasegroupid},
        MUSICBRAINZ_WORK_ID         => $alibRow->{musicbrainz_workid},

        # Work/Movement (for classical)
        WORK        => $alibRow->{work},
        MOVEMENT    => $alibRow->{movement},
        PART        => $alibRow->{part},

        # Album metadata
        COMPILATION => $alibRow->{compilation} ? 1 : 0,
        LABEL       => _splitMultiValue($alibRow->{label}),
        RELEASETYPE => _splitMultiValue($alibRow->{releasetype}),
        CATALOGNUMBER => $alibRow->{catalognumber} || $alibRow->{catalog},
        BARCODE     => $alibRow->{barcode},
        ASIN        => $alibRow->{asin},

        # Lyrics
        LYRICS      => $alibRow->{lyrics} || $alibRow->{unsyncedlyrics},

        # Additional metadata
        SUBTITLE    => _splitMultiValue($alibRow->{subtitle}),
        DISCSUBTITLE => $alibRow->{discsubtitle},
        GROUPING    => $alibRow->{grouping},
        RATING      => $alibRow->{rating},
        BPM         => $alibRow->{bpm},
        ISRC        => $alibRow->{isrc},

        # Comments
        COMMENT     => $alibRow->{comment},

        # ReplayGain
        REPLAYGAIN_TRACK_GAIN => $alibRow->{replaygain_track_gain},
        REPLAYGAIN_TRACK_PEAK => $alibRow->{replaygain_track_peak},
        REPLAYGAIN_ALBUM_GAIN => $alibRow->{replaygain_album_gain},
        REPLAYGAIN_ALBUM_PEAK => $alibRow->{replaygain_album_peak},
    };

    # Determine content type and lossless from extension
    my $ext = lc($alibRow->{__ext} || '');
    my ($content_type, $lossless) = _mapInternalContentType($alibRow);

    # Provide essential tags normally generated by native scanners so Schema can build albums etc.
    $tags->{CONTENT_TYPE} = $content_type;
    $tags->{AUDIO}        = 1;                  # treat all alib entries as audio tracks
    $tags->{FILESIZE}     = $alibRow->{__file_size_bytes};
    $tags->{TIMESTAMP}    = $alibRow->{__file_mtime} || time();
    $tags->{SECS}         = $alibRow->{__length_seconds} || 0;
    # Precise unit parsing for bitrate & samplerate:
    # Prefer textual columns (__bitrate like '2486.642 kb/s', __frequency like '192.0 kHz').
    # Fall back to numeric helper columns (__bitrate_num, __frequency_num).
    # LMS expects BITRATE in bits per second (integer), SAMPLERATE in Hz (integer).
    my ($scaledBitrate, $scaledRate);

    if (my $bitrateText = $alibRow->{__bitrate}) {
        if ($bitrateText =~ /([0-9]+(?:\.[0-9]+)?)\s*kb\/?s/i) {
            my $kbps = $1; $scaledBitrate = int($kbps * 1000 + 0.5);
        }
        elsif ($bitrateText =~ /([0-9]+)\s*$/) { # bare number, assume already bps if large
            my $val = $1; $scaledBitrate = ($val < 10000) ? int($val * 1000) : $val;
        }
    }
    if (!defined $scaledBitrate) {
        my $rawBitrate = $alibRow->{__bitrate_num};
        if (defined $rawBitrate) {
            # If raw < 10000 assume kbps; keep precision lost in _num (integer) vs text.
            $scaledBitrate = $rawBitrate < 10000 ? int($rawBitrate * 1000) : $rawBitrate;
        }
    }

    if (my $freqText = $alibRow->{__frequency}) {
        if ($freqText =~ /([0-9]+(?:\.[0-9]+)?)\s*kHz/i) {
            my $khz = $1; $scaledRate = int($khz * 1000 + 0.5);
        }
        elsif ($freqText =~ /([0-9]+)\s*Hz/i) {
            $scaledRate = $1; # already Hz
        }
    }
    if (!defined $scaledRate) {
        my $rawSamplerate = $alibRow->{__frequency_num};
        if (defined $rawSamplerate) {
            # If raw < 3000 assume kHz (covers 44.1, 48, 96, 192 etc); else treat as Hz.
            $scaledRate = $rawSamplerate < 3000 ? int($rawSamplerate * 1000 + 0.5) : $rawSamplerate;
        }
    }

    $tags->{BITRATE}    = $scaledBitrate if defined $scaledBitrate;
    $tags->{SAMPLERATE} = $scaledRate    if defined $scaledRate;
    $tags->{CHANNELS}     = $alibRow->{__channels} if defined $alibRow->{__channels};
    $tags->{LOSSLESS}     = $lossless;

    # Build info hash (matches Audio::Scan structure)
    my $info = {
        # File info
        file_size   => $alibRow->{__file_size_bytes},
        audio_size  => $alibRow->{__file_size_bytes},
        audio_offset => 0,

        # Audio properties
        bitrate     => $scaledBitrate,
        samplerate  => $scaledRate,
        song_length_ms => ($alibRow->{__length_seconds} || 0) * 1000,

        # Format
        lossless    => $lossless,
        vbr         => ($alibRow->{__mode} && $alibRow->{__mode} =~ /vbr/i) ? 1 : 0,
    };

    # Additional audio properties
    if (my $channels = $alibRow->{__channels}) {
        $info->{channels} = $channels;
    }
    if (my $bps = $alibRow->{__bitspersample}) {
        $info->{bits_per_sample} = $bps;
    }

    # NOTE: Removed previous heuristic placeholder filtering to allow raw alib contributor values
    # to pass through unchanged for deeper ingestion diagnostics.

    return {
        info => $info,
        tags => $tags,
    };
}

sub _mapInternalContentType {
    my ($row) = @_;
    my $ext = lc($row->{__ext} || '');
    my $filetype = lc($row->{__filetype} || '');

    # LMS internal short codes mapping
    my %map = (
        flac => 'flc',
        flc  => 'flc',
        mp3  => 'mp3',
        wv   => 'wv',
        wav  => 'wav',
        aiff => 'aif',
        aif  => 'aif',
        ape  => 'ape',
        tta  => 'tta',
        dff  => 'dff',
        dsf  => 'dsf',
        mpc  => 'mpc',
        ogg  => 'ogg',
        opus => 'ogg',    # LMS treats opus under ogg
        m4a  => 'mp4',    # container; refine below if ALAC
        aac  => 'mp4',
        alac => 'alc',
    );

    my $ct = $map{$ext} || 'unk';

    # Refine ALAC inside m4a: if filetype suggests Apple Lossless
    if ($ct eq 'mp4' && $filetype =~ /alac|apple\s+lossless/) {
        $ct = 'alc';
    }

    # Heuristic for WavPack DSD -> wvpx (LMS uses this when WAVPACKDSD flag set).
    # If bit depth is 1 and frequency above typical PCM (> 176400) assume DSD.
    if ($ct eq 'wv') {
        my $bps = $row->{__bitspersample};
        my $freq = $row->{__frequency_num};
        if (defined $bps && defined $freq && $bps == 1 && $freq && $freq > 176400) {
            $ct = 'wvpx';
        }
    }

    # Lossless determination based on internal code
    my %lossless = map { $_ => 1 } qw(flc wv wvpx alc ape wav aif dff dsf tta);
    my $isLossless = $lossless{$ct} ? 1 : 0;

    return ($ct, $isLossless);
}

sub _splitMultiValue {
    my $value = shift;
    return unless defined $value && length $value;

    # Split on double backslash delimiter used by alib
    my @values = map {
        my $v = $_;
        $v =~ s/^\s+|\s+$//g;
        $v;
    } split /\\\\/, $value;

    # Filter empty values
    @values = grep { length $_ } @values;

    return unless @values;

    # Return arrayref if multiple values, scalar if single value
    return @values > 1 ? \@values : $values[0];
}

1;
