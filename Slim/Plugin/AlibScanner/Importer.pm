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
use Storable qw();
use Scalar::Util qw(blessed);

my $log = logger('plugin.alibscanner');
my $prefs = preferences('plugin.alibscanner');

# Statement handle cache to reduce prepare() overhead
my %STH_CACHE;
sub _cached_sth {
    my ($sql) = @_;
    return $STH_CACHE{$sql} ||= Slim::Schema->dbh->prepare($sql);
}

# Cache for alib database handle and data
my $alibDbh;
my $alibCache = {};

# Track whether hooks are installed
my $hooksInstalled = 0;
my ($orig_AudioScan_scan, $orig_readTags, $orig_pathFromFileURL);
my $orig_mergeContributors; # store original Slim::Schema::_mergeAndCreateContributors for monkey patch instrumentation

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
        
        # Ensure scanner process registers us as a file-phase importer (weight 0) too.
        # This overrides any prior server-side registration, guaranteeing presence early.
        Slim::Music::Import->addImporter($class, {
            type   => 'file',
            weight => 0,
            use    => 1,
        });

        warn "AlibScanner::Importer registered (file-phase) and MediaFolderScan deleted\n";
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

    # Signature-based short-circuit: if alib file unchanged, normally skip ingestion.
    # Enhancement: if any rows have sqlmodded>0 we MUST ingest even if file signature unchanged.
    my @stat = stat($alibPath);
    if (@stat) {
        my ($size, $mtime) = ($stat[7], $stat[9]);
        my $sig = "$size:$mtime";
        my $lastSig = $prefs->get('lastAlibSig');
        if (defined $lastSig && $lastSig eq $sig) {
            my $moddedCount = 0;
            eval {
                my $tmpDbh = DBI->connect(
                    "dbi:SQLite:dbname=$alibPath", "", "",
                    { RaiseError => 1, AutoCommit => 1, sqlite_unicode => 1 }
                );
                if ($tmpDbh) {
                    ($moddedCount) = $tmpDbh->selectrow_array('SELECT COUNT(*) FROM alib WHERE sqlmodded > 0');
                    $tmpDbh->disconnect();
                }
            }; $log->warn("AlibScanner: sqlmodded probe failed: $@") if $@;
            if ($moddedCount > 0) {
                $log->info("AlibScanner: signature unchanged ($sig) but sqlmodded row count=$moddedCount; overriding skip and ingesting");
            }
            else {
                $log->info("AlibScanner: alib signature unchanged ($sig) and no sqlmodded rows; skipping ingestion pass");
                _removeHooks();
                Slim::Music::Import->endImporter($class);
                return 0;
            }
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
    # Discover available columns to guard against schema variance and avoid SELECT *
    my $ti = eval { $alibDbh->selectall_arrayref('PRAGMA table_info(alib)') };
    my %have;
    if ($ti) {
        for my $col (@$ti) {
            # PRAGMA table_info returns: cid,name,type,notnull,dflt_value,pk
            my $name = $col->[1];
            $have{$name} = 1 if defined $name;
        }
    }

    my @wanted = qw(
        __path title __filename_no_ext album track discnumber disc year originalyear
        artist albumartist composer conductor lyricist writer arranger ensemble performer
        engineer producer mixer remixer genre style mood musicbrainz_trackid musicbrainz_albumid
        musicbrainz_artistid musicbrainz_albumartistid musicbrainz_releasegroupid musicbrainz_workid
        work movement part compilation label releasetype catalognumber catalog barcode asin
        lyrics unsyncedlyrics subtitle discsubtitle grouping rating bpm isrc comment
        replaygain_track_gain replaygain_track_peak replaygain_album_gain replaygain_album_peak
        __ext __file_size_bytes __file_mtime __length_seconds __bitrate __bitrate_num __frequency
        __frequency_num __channels __bitspersample __mode sqlmodded
    );

    # Filter to existing columns only (grouping may be absent etc.)
    my @cols = grep { $have{$_} } @wanted;
    unless (@cols) {
        $log->error('AlibScanner: no expected columns found in alib schema; aborting cache load');
        return;
    }
    if (!$have{'__path'}) {
        $log->error('AlibScanner: required column __path missing; cannot proceed');
        return;
    }
    my @missing = grep { !$have{$_} } @wanted;
    if (@missing) {
        $log->info('AlibScanner: skipping absent alib columns: ' . join(',', @missing));
    }
    my $sql = 'SELECT ' . join(',', @cols) . ' FROM alib';
    my $sth = eval { $alibDbh->prepare($sql) };
    if (!$sth) {
        $log->error('AlibScanner: prepare failed for selective column query, falling back to SELECT *: ' . ($@||'unknown error'));
        $sth = $alibDbh->prepare('SELECT * FROM alib');
    }
    eval { $sth->execute(); };
    if ($@) {
        $log->error('AlibScanner: execute failed for selective column query, falling back to SELECT *: ' . $@);
        $sth = $alibDbh->prepare('SELECT * FROM alib');
        eval { $sth->execute(); };
        if ($@) {
            $log->error('AlibScanner: fallback SELECT * failed: ' . $@);
            return;
        }
    }

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
            while (my ($eurl) = $sth->fetchrow_array) {
                # Canonicalize URL the same way we do for alib entries to avoid false 'new' classifications
                my $canon = Slim::Utils::Misc::fixPath($eurl);
                $existing{$canon} = 1;
            }
            $sth->finish;
            $log->info('AlibScanner: preloaded existing track URL hash size=' . scalar(keys %existing));
        }
    }

    my (@newUrls, @changedUrls);
    for my $url (@urls) {
        my $row = $alibCache->{$url};
        if (!$existing{$url}) {
            push @newUrls, $url;
        }
        else {
            if ($row && defined $row->{sqlmodded} && $row->{sqlmodded} > 0) {
                push @changedUrls, $url;
            }
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
    
    # Early cache of logging prefs to avoid repeated lookups in tight loops
    my $debugContrib  = $prefs->get('debugPlaceholders');
    my $debugVerbose  = $debugContrib ? $prefs->get('debugPlaceholdersVerbose') : 0;
    my $anomalyChecks = $debugContrib ? $prefs->get('anomalyChecksEnabled') : 0;

    $log->error("Found $total tracks in alib (new=$newTotal changed=$changedTotal) to process");
    
    # Process each track
    my $count = 0;          # number of new tracks added
    my $updated = 0;        # number of existing tracks whose metadata was updated (sqlmodded)
    my $processedNew = 0;   # progress counter for new tracks
    my $processedChanged = 0; # progress counter for changed tracks
    my %albumSeen;       # distinct album ids (only if debugContrib)
    my $albumSamplesLogged = 0;
    # Process new tracks first
    for my $url (@newUrls) {
        my $row = $alibCache->{$url};
        eval {
            my $trackId = Slim::Schema->updateOrCreateBase({
                url        => $url,
                readTags   => 1,
                new        => 1,
                checkMTime => 0,
                commit     => 0,
            });
            if ($trackId) {
                $changes++;
                $count++;
                $processedNew++;
                if (defined $row->{__bitspersample} && $row->{__bitspersample} =~ /^(\d+)$/) {
                    my $bps = $1;
                    my $trackObj = Slim::Schema->rs('Track')->find($trackId);
                    if ($trackObj && !$trackObj->samplesize) {
                        $trackObj->set_column('samplesize', $bps);
                        eval { $trackObj->update; }; $log->warn("AlibScanner: failed to update samplesize for track $trackId url=$url: $@") if $@;
                    }
                }
                if ($debugContrib) {
                    my $dbh2 = Slim::Schema->dbh;
                    my $sthAlbum = _cached_sth('SELECT album FROM tracks WHERE id=?');
                    eval { $sthAlbum->execute($trackId); };
                    if (!$@) {
                        my ($albumId) = $sthAlbum->fetchrow_array;
                        if (defined $albumId && $albumId) {
                            $albumSeen{$albumId}++;
                            if ($albumSamplesLogged < 5) {
                                $log->error("ALBUMTRACE track=$trackId album=$albumId url=$url");
                                $albumSamplesLogged++;
                            }
                        }
                    }
                }
                if ($trackId && $debugContrib) {
                    my $sthP = _cached_sth(q{SELECT ct.role, c.name FROM contributor_track ct JOIN contributors c ON ct.contributor=c.id WHERE ct.track=?});
                    eval { $sthP->execute($trackId); };
                    if (!$@) {
                        my $rawComposer = $alibCache->{$url}->{composer};
                        my $rawConductor = $alibCache->{$url}->{conductor};
                        while (my ($r,$n) = $sthP->fetchrow_array) {
                            if ($anomalyChecks && $n =~ /^(ARTIST|ALBUMARTIST|TRACKARTIST|COMPOSER|CONDUCTOR|BAND|PERFORMER|LYRICIST|ARRANGER|ENGINEER|PRODUCER|MIXER|REMIXER)$/i && $r !~ /^[1-6]$/) {
                                $log->error("PLACEHOLDERTRACE unexpected roleMap track=$trackId url=$url role=$r name=$n");
                            }
                            if ($anomalyChecks && $n =~ /^(COMPOSER|CONDUCTOR|LYRICIST|PERFORMER)$/i) {
                                $log->error("PLACEHOLDERTRACE contributor track=$trackId role=$r name=$n") if $n =~ /^CONDUCTOR$/i && $r != 3;
                            }
                            if ($anomalyChecks && $n =~ /^CONDUCTOR$/i && $r == 2) {
                                $log->error("COMPOSER_ANOMALY track=$trackId url=$url composerContributorName=CONDUCTOR rawComposer='" . (defined $rawComposer ? $rawComposer : '') . "' rawConductor='" . (defined $rawConductor ? $rawConductor : '') . "'");
                            }
                        }
                        $sthP->finish;
                    }
                    eval {
                        my $tags = Slim::Formats::readTags($url) || {};
                        my @ctags = qw(ARTIST ALBUMARTIST COMPOSER CONDUCTOR LYRICIST ARRANGER BAND PERFORMER ENGINEER PRODUCER MIXER REMIXER);
                        my %dump;
                        for my $k (@ctags) {
                            next unless exists $tags->{$k};
                            my $v = $tags->{$k};
                            my $ref = ref $v;
                            my $out = $ref eq 'ARRAY' ? join('|', @$v) : (defined $v ? $v : '');
                            $dump{$k} = $out if defined $out && length $out;
                        }
                        my $tagDump = join(' ', map { $_ . "='" . $dump{$_} . "'" } sort keys %dump);
                        $log->error("TRACKCONTRIBTRACE tags track=$trackId url=$url $tagDump");
                        my $sthDb = _cached_sth(q{SELECT ct.role, c.name FROM contributor_track ct JOIN contributors c ON ct.contributor=c.id WHERE ct.track=?});
                        $sthDb->execute($trackId);
                        my @pairs;
                        while (my ($r,$n) = $sthDb->fetchrow_array) { push @pairs, $r . ':' . $n; }
                        $sthDb->finish;
                        $log->error("TRACKCONTRIBTRACE db track=$trackId url=$url roles=" . join('|', @pairs));
                    }; $log->warn("TRACKCONTRIBTRACE error (new track) url=$url: $@") if $@;
                    $log->error('-' x 80);
                }
            }
        };
        if ($@) { $log->error("Error processing $url: $@"); }
        if ($processedNew % 500 == 0) {
            Slim::Schema->forceCommit;
            my $distinctAlbums = $debugContrib ? scalar keys %albumSeen : 0;
            my $info = "added=$count newProgress=$processedNew/$newTotal updated=$updated" . ($debugContrib ? " albums=$distinctAlbums" : '');
            $log->error("Processed new $processedNew / $newTotal (added=$count) changed=$updated" . ($debugContrib ? " distinctAlbums=$distinctAlbums" : ''));
            eval { $progressNew->update($info, $processedNew) };
        }
    }
    # Extra boundary update if final count divisible by 500
    if ($processedNew % 500 == 0) { my $info = "added=$count finalNew=$processedNew/$newTotal"; eval { $progressNew->update($info, $processedNew) }; }

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
                $changes++; # count metadata updates as changes so UI "changed" operations are visible
                $processedChanged++;
                # Populate samplesize for changed tracks if now present
                my $row = $alibCache->{$url};
                if ($row && defined $row->{__bitspersample} && $row->{__bitspersample} =~ /^(\d+)$/) {
                    my $bps = $1;
                    my $trackObj;
                    if (blessed($trackObjOrId)) {
                        $trackObj = $trackObjOrId;
                    } else {
                        $trackObj = Slim::Schema->rs('Track')->find($trackObjOrId);
                    }
                    if ($trackObj && !$trackObj->samplesize) {
                        $trackObj->set_column('samplesize', $bps);
                        eval { $trackObj->update; }; $log->warn("AlibScanner: failed to update samplesize for changed track url=$url: $@") if $@;
                    }
                }
                if ($prefs->get('debugPlaceholders')) {
                    my $dbh2 = Slim::Schema->dbh;
                    my $idLookup = _cached_sth('SELECT id FROM tracks WHERE url=?');
                    eval { $idLookup->execute($url); };
                    if (!$@) {
                        my ($tid) = $idLookup->fetchrow_array;
                        $idLookup->finish;
                        if ($tid) {
                            my $sthP = _cached_sth(q{SELECT ct.role, c.name FROM contributor_track ct JOIN contributors c ON ct.contributor=c.id WHERE ct.track=?});
                            eval { $sthP->execute($tid); };
                            if (!$@) {
                                while (my ($r,$n) = $sthP->fetchrow_array) {
                                    if ($n =~ /^(CONDUCTOR|LYRICIST|PERFORMER)$/i && $r == 2) { # composer role misuse
                                        $log->error("PLACEHOLDERTRACE updated track id=$tid url=$url composerName=$n role=$r suspect");
                                    }
                                }
                                $sthP->finish;
                            }
                            # Correlate sanitized tags vs DB contributor rows for changed tracks
                            eval {
                                my $tags = Slim::Formats::readTags($url) || {};
                                my @ctags = qw(ARTIST ALBUMARTIST COMPOSER CONDUCTOR LYRICIST ARRANGER BAND PERFORMER ENGINEER PRODUCER MIXER REMIXER);
                                my %dump;
                                for my $k (@ctags) {
                                    next unless exists $tags->{$k};
                                    my $v = $tags->{$k};
                                    my $ref = ref $v;
                                    my $out = $ref eq 'ARRAY' ? join('|', @$v) : (defined $v ? $v : '');
                                    $dump{$k} = $out if defined $out && length $out;
                                }
                                my $tagDump = join(' ', map { $_ . "='" . $dump{$_} . "'" } sort keys %dump);
                                $log->error("TRACKCONTRIBTRACE tags track=$tid url=$url $tagDump");
                                my $sthDb = _cached_sth(q{SELECT ct.role, c.name FROM contributor_track ct JOIN contributors c ON ct.contributor=c.id WHERE ct.track=?});
                                $sthDb->execute($tid);
                                my @pairs;
                                while (my ($r,$n) = $sthDb->fetchrow_array) { push @pairs, $r . ':' . $n; }
                                $sthDb->finish;
                                $log->error("TRACKCONTRIBTRACE db track=$tid url=$url roles=" . join('|', @pairs));
                            }; $log->warn("TRACKCONTRIBTRACE error (changed track) url=$url: $@") if $@;
                            # Separator line between track log blocks
                            $log->error('-' x 80);
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
            my $distinctAlbums = $debugContrib ? scalar keys %albumSeen : 0;
            my $info = "updated=$updated changedProgress=$processedChanged/$changedTotal added=$count" . ($debugContrib ? " albums=$distinctAlbums" : '');
            $log->error("Processed changed $processedChanged / $changedTotal (added=$count updated=$updated" . ($debugContrib ? " distinctAlbums=$distinctAlbums" : '') . ")");
            eval { $progressChanged && $progressChanged->update($info, $processedChanged) };
        }
    }
    
    # Final commit
    Slim::Schema->forceCommit;
    eval {
        my $finalInfoNew = "added=$count totalNew=$processedNew/$newTotal updated=$updated";
        $progressNew->update($finalInfoNew, $processedNew);
        $progressNew->final($processedNew);
    };
    eval {
        if ($progressChanged) {
            my $finalInfoChanged = "updated=$updated totalChanged=$processedChanged/$changedTotal added=$count";
            $progressChanged->update($finalInfoChanged, $processedChanged);
            $progressChanged->final($processedChanged);
        }
    };
    if ($debugContrib) {
        my $finalDistinctAlbums = scalar keys %albumSeen;
        my $processedTotal = $processedNew + $processedChanged;
        $log->error("ALBUMTRACE final distinct album ids=$finalDistinctAlbums (sample logged=$albumSamplesLogged) added=$count updated=$updated totalProcessed=$processedTotal newProcessed=$processedNew changedProcessed=$processedChanged");
    }

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
                    eval { $delProgress->update(undef, $d); };
                }
            }
            # finalize deletion progress
            eval { $delProgress->update(undef, $d); $delProgress->final($d); };
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
                if ($prefs->get('debugPlaceholders')) {
                    # Log pre-sanitization contributor tags
                    my @ctags = qw(ARTIST ALBUMARTIST COMPOSER CONDUCTOR LYRICIST ARRANGER BAND PERFORMER ENGINEER PRODUCER MIXER REMIXER);
                    my %dump;
                    for my $k (@ctags) {
                        next unless exists $tags->{$k};
                        my $v = $tags->{$k};
                        my $ref = ref $v;
                        my $out = $ref eq 'ARRAY' ? join('|', @$v) : (defined $v ? $v : '');
                        $dump{$k} = $out if defined $out && length $out;
                    }
                    my $dumpStr = join(' ', map { "$_='" . $dump{$_} . "'" } sort keys %dump);
                    $log->error("READTAGSTRACE scan preSanitize url=$url $dumpStr");
                }
                eval { Slim::Formats::sanitizeTagValues($tags, $url); };
                $log->warn("Error sanitizing tags in scan for $url: $@") if $@;
                if ($prefs->get('debugPlaceholdersVerbose')) {
                    for my $mb (grep { /^MUSICBRAINZ.*ID$/ } keys %$tags) {
                        my $val = $tags->{$mb};
                        my $ref = ref $val;
                        my $out = $ref eq 'ARRAY' ? join(',', @$val) : $val;
                        $log->error("MBIDTRACE scan $mb ref=$ref url=$url val=$out") if defined $out;
                    }
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
                if ($prefs->get('debugPlaceholders')) {
                    my @ctags = qw(ARTIST ALBUMARTIST COMPOSER CONDUCTOR LYRICIST ARRANGER BAND PERFORMER ENGINEER PRODUCER MIXER REMIXER);
                    my %dump;
                    for my $k (@ctags) {
                        next unless exists $tags->{$k};
                        my $v = $tags->{$k};
                        my $ref = ref $v;
                        my $out = $ref eq 'ARRAY' ? join('|', @$v) : (defined $v ? $v : '');
                        $dump{$k} = $out if defined $out && length $out;
                    }
                    my $dumpStr = join(' ', map { "$_='" . $dump{$_} . "'" } sort keys %dump);
                    $log->error("READTAGSTRACE readTags preSanitize url=$url $dumpStr");
                }
                eval { Slim::Formats::sanitizeTagValues($tags, $url); };
                $log->warn("Error sanitizing tags for $url: $@") if $@;
                if ($prefs->get('debugPlaceholdersVerbose')) {
                    for my $mb (grep { /^MUSICBRAINZ.*ID$/ } keys %$tags) {
                        my $val = $tags->{$mb};
                        my $ref = ref $val;
                        my $out = $ref eq 'ARRAY' ? join(',', @$val) : $val;
                        $log->error("MBIDTRACE readTags $mb ref=$ref url=$url val=$out") if defined $out;
                    }
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

    # Monkey patch Slim::Schema::_mergeAndCreateContributors for deep instrumentation (no core file edits)
    eval {
        no warnings 'redefine';
        $orig_mergeContributors ||= *Slim::Schema::_mergeAndCreateContributors{CODE};
        *Slim::Schema::_mergeAndCreateContributors = sub {
            my ($self, $attributes, $isCompilation, $create) = @_;
            my $doDebug = $prefs->get('debugPlaceholders');
            if ($doDebug) {
                my $rawComposerAttr = $attributes->{'COMPOSER'};
                my $rawConductorAttr = $attributes->{'CONDUCTOR'};
                my $cVal = defined $rawComposerAttr ? (ref($rawComposerAttr) eq 'ARRAY' ? join('|', @{$rawComposerAttr}) : $rawComposerAttr) : '';
                my $dVal = defined $rawConductorAttr ? (ref($rawConductorAttr) eq 'ARRAY' ? join('|', @{$rawConductorAttr}) : $rawConductorAttr) : '';
                $log->error("MERGEATTRTRACE pre composerAttr='${cVal}' conductorAttr='${dVal}' create=$create compilation=" . ($isCompilation?1:0));
            }

            my $contributors = $orig_mergeContributors->(@_);

            if ($doDebug) {
                my $dbh = Slim::Schema->dbh;
                if (my $cmp = $contributors->{'COMPOSER'}) {
                    my @names;
                    for my $cid (@$cmp) {
                        my ($nm) = $dbh->selectrow_array('SELECT name FROM contributors WHERE id=?', undef, $cid);
                        push @names, defined $nm ? $nm : '(undef)';
                    }
                    my $namesStr = join('|', @names);
                    $log->error("MERGEPOSTTRACE composerContributorNames='${namesStr}'");
                    my $rawComposerAttr = $attributes->{'COMPOSER'};
                    my $cEmpty = !defined $rawComposerAttr || (ref($rawComposerAttr) ne 'ARRAY' && $rawComposerAttr eq '') || (ref($rawComposerAttr) eq 'ARRAY' && !@{$rawComposerAttr});
                    if ($namesStr =~ /\bCONDUCTOR\b/i && $cEmpty) {
                        $log->error("COMPOSER_SOURCE_MISMATCH attrEmpty contributorSetContainsCONDUCTOR names='${namesStr}'");
                    }
                }
                if (my $cond = $contributors->{'CONDUCTOR'}) {
                    my @names;
                    for my $cid (@$cond) {
                        my ($nm) = $dbh->selectrow_array('SELECT name FROM contributors WHERE id=?', undef, $cid);
                        push @names, defined $nm ? $nm : '(undef)';
                    }
                    $log->error("MERGEPOSTTRACE conductorContributorNames='" . join('|', @names) . "'");
                }
                # Separator line to visually separate merge trace blocks
                $log->error('-' x 80);
            }
            return $contributors;
        };
    };
    $log->error('AlibScanner: merge contributor monkey patch ' . ($@ ? "FAILED: $@" : 'installed'));
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
    if ($orig_mergeContributors) {
        no warnings 'redefine';
        *Slim::Schema::_mergeAndCreateContributors = $orig_mergeContributors;
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
    # Build tags hash incrementally to allow per-role instrumentation & shift detection
    my $tags = {};

    # Core metadata (single assignments unlikely to cause shift, keep simple)
    $tags->{TITLE}    = $alibRow->{title} || $alibRow->{__filename_no_ext} || '';
    $tags->{ALBUM}    = $alibRow->{album} || '';
    $tags->{TRACKNUM} = $alibRow->{track};
    $tags->{DISC}     = $alibRow->{discnumber} || $alibRow->{disc};
    $tags->{DISCC}    = undef;
    $tags->{YEAR}     = $alibRow->{year} || $alibRow->{originalyear};
    $tags->{DATE}     = $alibRow->{originaldate} || $alibRow->{originalreleasedate};

    # EARLY SHORT-CIRCUIT: if contributor debug disabled, avoid building closure array
    if ($prefs->get('debugPlaceholders')) {
        my @contribBuild = (
            [ ARTIST      => sub { _splitMultiValue($alibRow->{artist}) } ],
            [ ALBUMARTIST => sub { _splitMultiValue($alibRow->{albumartist}) } ],
            [ COMPOSER    => sub { _splitMultiValue($alibRow->{composer}) } ],
            [ CONDUCTOR   => sub { _splitMultiValue($alibRow->{conductor}) } ],
            [ LYRICIST    => sub { _splitMultiValue($alibRow->{lyricist} || $alibRow->{writer}) } ],
            [ ARRANGER    => sub { _splitMultiValue($alibRow->{arranger}) } ],
            [ BAND        => sub { _splitMultiValue($alibRow->{ensemble}) } ],
            [ PERFORMER   => sub { _splitMultiValue($alibRow->{performer}) } ],
            [ ENGINEER    => sub { _splitMultiValue($alibRow->{engineer}) } ],
            [ PRODUCER    => sub { _splitMultiValue($alibRow->{producer}) } ],
            [ MIXER       => sub { _splitMultiValue($alibRow->{mixer}) } ],
            [ REMIXER     => sub { _splitMultiValue($alibRow->{remixer}) } ],
            [ GENRE       => sub { _splitMultiValue($alibRow->{genre}) } ],
            [ STYLE       => sub { _splitMultiValue($alibRow->{style}) } ],
            [ MOOD        => sub { _splitMultiValue($alibRow->{mood}) } ],
        );
        my $verbose = $prefs->get('debugPlaceholdersVerbose');
        my $anomalyEnabled = $prefs->get('anomalyChecksEnabled');
        for (my $i = 0; $i < @contribBuild; $i++) {
            my ($role, $code) = @{$contribBuild[$i]};
            my $rawInput = $alibRow->{ lc $role };
            my $val = $code->();
            $tags->{$role} = $val;
            my $raw = $alibRow->{lc $role};
            my $scalarVal = ref($val) eq 'ARRAY' ? join('|', @$val) : (defined $val ? $val : '');
            # High-volume SPLITTRACE only when verbose flag enabled
            if ($verbose) {
                $log->error('SPLITTRACE url=' . Slim::Utils::Misc::fixPath($file) . " role=$role rawInput='" . (defined $rawInput ? $rawInput : '') . "' returned='" . (defined $scalarVal ? $scalarVal : '') . "'");
            }
            if ($anomalyEnabled && (!defined $raw || $raw eq '') && defined $scalarVal && $scalarVal ne '') {
                if ($i < @contribBuild - 1) {
                    my $nextRole = $contribBuild[$i+1]->[0];
                    if ($scalarVal eq $nextRole) {
                        $log->error('ASSIGN_SHIFT url=' . Slim::Utils::Misc::fixPath($file) . " role=$role placeholder='$scalarVal' nextRoleRaw='" . (defined $alibRow->{lc $nextRole} ? $alibRow->{lc $nextRole} : '') . "'");
                    }
                }
                my %roleNames = map { $_->[0] => 1 } @contribBuild;
                if ($roleNames{$scalarVal}) {
                    $log->error('ASSIGN_PLACEHOLDER url=' . Slim::Utils::Misc::fixPath($file) . " role=$role rawEmpty constructed='$scalarVal'");
                }
            }
        }
    }
    else {
        # Non-debug fast path: direct assignments without closure indirection
        $tags->{ARTIST}      = _splitMultiValue($alibRow->{artist});
        $tags->{ALBUMARTIST} = _splitMultiValue($alibRow->{albumartist});
        $tags->{COMPOSER}    = _splitMultiValue($alibRow->{composer});
        $tags->{CONDUCTOR}   = _splitMultiValue($alibRow->{conductor});
        $tags->{LYRICIST}    = _splitMultiValue($alibRow->{lyricist} || $alibRow->{writer});
        $tags->{ARRANGER}    = _splitMultiValue($alibRow->{arranger});
        $tags->{BAND}        = _splitMultiValue($alibRow->{ensemble});
        $tags->{PERFORMER}   = _splitMultiValue($alibRow->{performer});
        $tags->{ENGINEER}    = _splitMultiValue($alibRow->{engineer});
        $tags->{PRODUCER}    = _splitMultiValue($alibRow->{producer});
        $tags->{MIXER}       = _splitMultiValue($alibRow->{mixer});
        $tags->{REMIXER}     = _splitMultiValue($alibRow->{remixer});
        $tags->{GENRE}       = _splitMultiValue($alibRow->{genre});
        $tags->{STYLE}       = _splitMultiValue($alibRow->{style});
        $tags->{MOOD}        = _splitMultiValue($alibRow->{mood});
    }

    # MusicBrainz & other ancillary tags (unchanged from previous logic)
    $tags->{MUSICBRAINZ_TRACK_ID}         = $alibRow->{musicbrainz_trackid};
    $tags->{MUSICBRAINZ_ALBUM_ID}         = $alibRow->{musicbrainz_albumid};
    $tags->{MUSICBRAINZ_ARTIST_ID}        = $alibRow->{musicbrainz_artistid};
    $tags->{MUSICBRAINZ_ALBUM_ARTIST_ID}  = $alibRow->{musicbrainz_albumartistid};
    $tags->{MUSICBRAINZ_RELEASE_GROUP_ID} = $alibRow->{musicbrainz_releasegroupid};
    $tags->{MUSICBRAINZ_WORK_ID}          = $alibRow->{musicbrainz_workid};

    $tags->{WORK}        = $alibRow->{work};
    $tags->{MOVEMENT}    = $alibRow->{movement};
    $tags->{PART}        = $alibRow->{part};
    $tags->{COMPILATION} = $alibRow->{compilation} ? 1 : 0;
    $tags->{LABEL}       = _splitMultiValue($alibRow->{label});
    $tags->{RELEASETYPE} = _splitMultiValue($alibRow->{releasetype});
    $tags->{CATALOGNUMBER} = $alibRow->{catalognumber} || $alibRow->{catalog};
    $tags->{BARCODE}     = $alibRow->{barcode};
    $tags->{ASIN}        = $alibRow->{asin};
    $tags->{LYRICS}      = $alibRow->{lyrics} || $alibRow->{unsyncedlyrics};
    $tags->{SUBTITLE}    = _splitMultiValue($alibRow->{subtitle});
    $tags->{DISCSUBTITLE}= $alibRow->{discsubtitle};
    $tags->{GROUPING}    = $alibRow->{grouping};
    $tags->{RATING}      = $alibRow->{rating};
    $tags->{BPM}         = $alibRow->{bpm};
    $tags->{ISRC}        = $alibRow->{isrc};
    $tags->{COMMENT}     = $alibRow->{comment};
    $tags->{REPLAYGAIN_TRACK_GAIN} = $alibRow->{replaygain_track_gain};
    $tags->{REPLAYGAIN_TRACK_PEAK} = $alibRow->{replaygain_track_peak};
    $tags->{REPLAYGAIN_ALBUM_GAIN} = $alibRow->{replaygain_album_gain};
    $tags->{REPLAYGAIN_ALBUM_PEAK} = $alibRow->{replaygain_album_peak};

    # Earliest possible instrumentation point: dump immediately after tag construction
    if ($prefs->get('debugPlaceholders')) {
        my $verbose = $prefs->get('debugPlaceholdersVerbose');
        my $anomalyEnabled = $prefs->get('anomalyChecksEnabled');
        my @rolesPre = qw(ARTIST ALBUMARTIST COMPOSER CONDUCTOR LYRICIST ARRANGER BAND PERFORMER ENGINEER PRODUCER MIXER REMIXER GENRE STYLE MOOD);
        my %preFlat; for my $rk (@rolesPre) { my $v = $tags->{$rk}; $preFlat{$rk} = ref($v) eq 'ARRAY' ? join('|', @$v) : (defined $v ? $v : ''); }
        if ($verbose) {
            require Data::Dumper; local $Data::Dumper::Terse=1; local $Data::Dumper::Indent=0;
            $log->error('PRECONSTRUCTTRACE url=' . Slim::Utils::Misc::fixPath($file) . ' data=' . Data::Dumper::Dumper(\%preFlat));
        }
        if ($verbose) {
            for (my $i = 0; $i < @rolesPre - 1; $i++) {
                my $r1 = $rolesPre[$i]; my $r2 = $rolesPre[$i+1];
                my $rawFieldVal = $alibRow->{lc $r1};
                my $val = $preFlat{$r1};
                if ($anomalyEnabled && (!defined $rawFieldVal || $rawFieldVal eq '') && defined $val && $val eq $r2) {
                    $log->error('CONSTRUCT_SHIFT url=' . Slim::Utils::Misc::fixPath($file) . " role=$r1 placeholder='$val' nextRoleRaw='" . (defined $alibRow->{lc $r2} ? $alibRow->{lc $r2} : '') . "'");
                }
            }
            my %roleNameMap = map { $_ => 1 } @rolesPre;
            for my $r (@rolesPre) {
                my $raw = $alibRow->{lc $r};
                my $val = $preFlat{$r};
                next unless $anomalyEnabled && defined $val && $val ne '' && $roleNameMap{$val} && (!defined $raw || $raw eq '');
                $log->error('CONSTRUCT_PLACEHOLDER_DETAIL url=' . Slim::Utils::Misc::fixPath($file) . " role=$r rawEmpty constructed='$val'");
            }
        }
    }

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

    if ($prefs->get('debugPlaceholders')) {
        my $verbose = $prefs->get('debugPlaceholdersVerbose');
        my $anomalyEnabled = $prefs->get('anomalyChecksEnabled');
        # Stage 1: immediate dump of freshly constructed contributor-related fields before any later mutation.
        my @rolesOrder = qw(ARTIST ALBUMARTIST COMPOSER CONDUCTOR LYRICIST ARRANGER BAND PERFORMER ENGINEER PRODUCER MIXER REMIXER GENRE STYLE MOOD);
        my %initial; for my $rk (@rolesOrder) { $initial{$rk} = $tags->{$rk}; }
        my %initialFlat; for my $k (keys %initial) { my $v = $initial{$k}; my $out = ref($v) eq 'ARRAY' ? join('|', @$v) : (defined $v ? $v : ''); $initialFlat{$k} = $out; }
        if ($verbose) {
            require Data::Dumper; local $Data::Dumper::Terse = 1; local $Data::Dumper::Indent = 0;
            $log->error('CONTRIB_STAGE1 url=' . Slim::Utils::Misc::fixPath($file) . ' data=' . Data::Dumper::Dumper(\%initialFlat));
        }

        # Insert temporary sentinels for truly empty contributor fields to detect external replacement later.
        # We won't return them; they are for logging only.
        if ($verbose) {
            my %sentinels; for my $rk (@rolesOrder) { next if defined $tags->{$rk}; $sentinels{$rk} = '__EMPTY__'; }
            if (%sentinels) {
                $log->error('CONTRIB_SENTINELS url=' . Slim::Utils::Misc::fixPath($file) . ' roles=' . join(',', sort keys %sentinels));
            }
        }
        # We don't actually modify $tags with sentinels to avoid polluting DB; just record.

        my @ctags = qw(ARTIST ALBUMARTIST COMPOSER CONDUCTOR LYRICIST ARRANGER BAND PERFORMER ENGINEER PRODUCER MIXER REMIXER);
        my %dump;
        for my $k (@ctags) {
            next unless exists $tags->{$k};
            my $v = $tags->{$k};
            my $ref = ref $v;
            my $out = $ref eq 'ARRAY' ? join('|', @$v) : (defined $v ? $v : '');
            $dump{$k} = $out if defined $out && length $out;
        }
        my $dumpStr = join(' ', map { "$_='" . $dump{$_} . "'" } sort keys %dump);
        my $rawComposer = defined $alibRow->{composer} ? $alibRow->{composer} : '';
        my $rawConductor = defined $alibRow->{conductor} ? $alibRow->{conductor} : '';
        if ($verbose && $anomalyEnabled) {
            $log->error("TAGTRACE url=$url rawComposer='${rawComposer}' rawConductor='${rawConductor}' $dumpStr");
        }

        # If any tag value equals a contributor role name while raw field is empty, dump raw alib row subset
        my %roleNames = map { $_ => 1 } qw(ARTIST ALBUMARTIST COMPOSER CONDUCTOR LYRICIST ARRANGER BAND PERFORMER ENGINEER PRODUCER MIXER REMIXER);
        my $needsRowDump;
        for my $r (keys %roleNames) {
            my $rawField = lc $r; # alib column naming
            my $rawVal = $alibRow->{$rawField};
            my $tagVal = $dump{$r};
            if ((defined $tagVal && $roleNames{$tagVal}) && (!defined $rawVal || $rawVal eq '')) {
                $needsRowDump = 1; last;
            }
        }
        if ($anomalyEnabled && $needsRowDump) {
            require Data::Dumper;
            local $Data::Dumper::Terse = 1; local $Data::Dumper::Indent = 0;
            my %subset;
            for my $f (qw(artist albumartist composer conductor lyricist writer arranger band ensemble performer engineer producer mixer remixer genre style mood)) {
                $subset{$f} = $alibRow->{$f} if exists $alibRow->{$f};
            }
            $log->error('ROLEPLACEHOLDER_ROW url=' . $url . ' rawSubset=' . Data::Dumper::Dumper(\%subset));
        }
        # Detect mismatches where tag value exists but raw field empty (possible role contamination)
        for my $role (qw(COMPOSER CONDUCTOR LYRICIST ARRANGER PERFORMER BAND ENGINEER PRODUCER MIXER REMIXER ARTIST ALBUMARTIST)) {
            my $rawFieldName = lc($role); # alib column naming convention
            my $rawVal = $alibRow->{$rawFieldName};
            my $tagVal = $dump{$role};
            if ($anomalyEnabled && (!defined $rawVal || $rawVal eq '') && defined $tagVal && $tagVal ne '') {
                $log->error("ROLEMISMATCH url=$url role=$role rawEmpty tagVal='${tagVal}'");
            }
        }
        # Special focus: conductor tag populated while raw conductor empty
        if ($anomalyEnabled && (!defined $alibRow->{conductor} || $alibRow->{conductor} eq '') && defined $dump{CONDUCTOR} && $dump{CONDUCTOR} ne '') {
            require Data::Dumper;
            local $Data::Dumper::Terse = 1; local $Data::Dumper::Indent = 0;
            my $rowDump = Data::Dumper::Dumper($alibRow);
            $log->error("CONDUCTOR_MISMATCH url=$url rawConductorEmpty tagConductor='" . $dump{CONDUCTOR} . "' rowDump=$rowDump");
        }

        # (ROLESHIFT & snapshot/revert logic removed after validation that shift no longer occurs)
    }

    return {
        info => $info,
        tags => _finalizeTags($tags, $alibRow),
    };
}

# Internal helper to optionally revert placeholder shifts when debugging
sub _finalizeTags {
    my ($tags, $alibRow) = @_;
    # Revert logic removed; tags returned as-constructed for transparency.
    return $tags;
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
