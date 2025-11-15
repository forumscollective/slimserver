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
    my $progress = Slim::Utils::Progress->new({
        type  => 'importer',
        name  => 'AlibScanner',
        total => $total,
    });
    
    $log->error("Found " . scalar(@urls) . " tracks in alib to process");
    
    # Process each track
    my $count = 0;
    my %albumSeen;       # distinct album ids
    my $albumSamplesLogged = 0;
    for my $url (@urls) {
        # Check if track already exists in database
        my $dbh = Slim::Schema->dbh;
        my $exists = $dbh->selectrow_array("SELECT 1 FROM tracks WHERE url = ?", undef, $url);
        
        if (!$exists) {
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
                }
            };
            
            if ($@) {
                $log->error("Error processing $url: $@");
            }
            
            # Commit every 500 tracks to avoid corruption
            if ($count % 500 == 0) {
                Slim::Schema->forceCommit;
                my $distinctAlbums = scalar keys %albumSeen;
                $log->error("Processed $count tracks so far... distinctAlbums=$distinctAlbums");
            }
        }

        # Progress update every 200 tracks (avoid excessive DB writes)
        if ($count % 200 == 0) {
            eval { $progress->update($count) };
        }
    }
    
    # Final commit
    Slim::Schema->forceCommit;
    eval { $progress->update($count); $progress->finalize; };
    my $finalDistinctAlbums = scalar keys %albumSeen;
    $log->error("ALBUMTRACE final distinct album ids=$finalDistinctAlbums (sample logged=$albumSamplesLogged)");
    
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
        my $url = shift;
        # Strip file:// prefix and return the path
        my $path = $url;
        $path =~ s|^file://||;
        return $path;
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
    my ($content_type, $lossless) = _getTypeInfo($ext);

    # Provide essential tags normally generated by native scanners so Schema can build albums etc.
    $tags->{CONTENT_TYPE} = $content_type;
    $tags->{AUDIO}        = 1;                  # treat all alib entries as audio tracks
    $tags->{FILESIZE}     = $alibRow->{__file_size_bytes};
    $tags->{TIMESTAMP}    = $alibRow->{__file_mtime} || time();
    $tags->{SECS}         = $alibRow->{__length_seconds} || 0;
    $tags->{BITRATE}      = $alibRow->{__bitrate_num};
    $tags->{SAMPLERATE}   = $alibRow->{__frequency_num};
    $tags->{CHANNELS}     = $alibRow->{__channels} if defined $alibRow->{__channels};
    $tags->{LOSSLESS}     = $lossless;

    # Build info hash (matches Audio::Scan structure)
    my $info = {
        # File info
        file_size   => $alibRow->{__file_size_bytes},
        audio_size  => $alibRow->{__file_size_bytes},
        audio_offset => 0,

        # Audio properties
        bitrate     => $alibRow->{__bitrate_num},
        samplerate  => $alibRow->{__frequency_num},
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

    return {
        info => $info,
        tags => $tags,
    };
}

sub _getTypeInfo {
    my $ext = shift;

    my %types = (
        # Lossless
        'flac' => ['audio/flac', 1],
        'alac' => ['audio/x-m4a', 1],
        'm4a'  => ['audio/x-m4a', 1],
        'ape'  => ['audio/x-monkeys-audio', 1],
        'wv'   => ['audio/x-wavpack', 1],
        'wav'  => ['audio/wav', 1],
        'aiff' => ['audio/aiff', 1],
        'aif'  => ['audio/aiff', 1],
        'tta'  => ['audio/x-tta', 1],
        'dff'  => ['audio/dff', 1],
        'dsf'  => ['audio/dsf', 1],

        # Lossy
        'mp3'  => ['audio/mpeg', 0],
        'ogg'  => ['audio/ogg', 0],
        'opus' => ['audio/ogg', 0],
        'mpc'  => ['audio/x-musepack', 0],
        'aac'  => ['audio/aac', 0],
    );

    my $info = $types{$ext} || ['audio/unknown', 0];
    return @$info;
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
