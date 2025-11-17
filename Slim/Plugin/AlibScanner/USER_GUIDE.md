# AlibScanner Plugin User Guide

## Overview
AlibScanner replaces Lyrion / Logitech Media Server's (LMS) traditional filesystem-based media scanning with direct ingestion from an external SQLite metadata database ("alib" / TagMinder). Instead of opening, parsing, and tagging each audio file, LMS builds and updates `library.db` solely from the rows stored in your alib database.

This yields:
- Faster rescans (O(changed rows))
- Lower CPU and I/O usage
- Consistent tag interpretation across formats
- Optional contributor anomaly diagnostics for troubleshooting

If the plugin is enabled and a valid alib database path is set, the native `MediaFolderScan` importer is disabled and all scanning phases are handled by AlibScanner.

## Prerequisites
- Lyrion Music Server 9.0.0 or newer.
- A populated SQLite alib database containing one row per track with required core columns (at minimum: `__path`).
- Read access for the LMS scanner process to the database file.

## Installation & Enablement
1. Place the plugin in the LMS `Slim/Plugin/AlibScanner` directory (already present if using a distribution including it).
2. Restart LMS.
3. In the Web UI: Settings > Plugins > locate "Alib Scanner" and ensure it is enabled (or use the plugin's own settings page under Settings > Advanced > Alib Scanner if exposed).
4. Open Settings > Alib Scanner (basic.html) and set:
   - Enable Alib Scanning (checkbox)
   - Alib Database Path (full path, e.g. `/var/lib/tagminder/alib.db`)
5. Save settings. The next scan (automatic or manual rescan) will use AlibScanner.

## How It Works
- On initialization, if `enabled` and `alibdb` are set, the plugin registers its importer with weight 0 (runs before native importers) and disables `MediaFolderScan`.
- During scan, the importer loads selected columns from the alib table into an in-memory cache keyed by canonical LMS URL (normalized via `Slim::Utils::Misc::fixPath`).
- Existing LMS track URLs are preloaded and canonicalized; alib rows whose URL is not present are treated as new; rows with `sqlmodded > 0` are treated as changed.
- New and changed tracks are processed: LMS track objects are created/updated via `Slim::Schema->updateOrCreateBase(readTags => 1)` which triggers tag hooks overridden to read from alib instead of disk.
- Contributor and album diagnostics execute only if debug preferences are enabled.
- Deletions: any LMS URL not found in the alib cache is considered deleted and removed.

## Required & Optional alib Columns
AlibScanner performs dynamic schema introspection (`PRAGMA table_info(alib)`) and selects only present columns. Minimum required: `__path`. Common useful columns include standard tags (title, album, artist, genre, track, disc, year) plus extended metadata (MusicBrainz IDs, technical fields like `__length_seconds`, `__bitspersample`, etc.). Missing optional columns are logged once and skipped.

## Preferences (Settings Page)
| Preference | Purpose | Default |
|------------|---------|---------|
| Enable Alib Scanning (`enabled`) | Activates ingestion from alib and disables filesystem scan | Off |
| Alib Database Path (`alibdb`) | Path to SQLite database file | Empty |
| Debug Placeholder Contributors (`debugPlaceholders`) | Enables contributor anomaly instrumentation | Off |
| Verbose Placeholder Diagnostics (`debugPlaceholdersVerbose`) | High-volume per-track placeholder/MBID traces | Off |
| Baseline Anomaly Checks (`anomalyChecksEnabled`) | Additional role mismatch / placeholder shift diagnostics | Off |

### When to Enable Diagnostics
Enable `debugPlaceholders` only when investigating contributor role anomalies (e.g., `CONDUCTOR` appearing as a composer). Turn off for normal operation to minimize overhead. `debugPlaceholdersVerbose` should generally remain off except for deep debugging sessions due to log volume.

## Rescan Behavior
- A full rescan reads all alib rows; classification is O(N) with lightweight hashing.
- A changed scan (auto-rescan) behaves the same; only rows with `sqlmodded > 0` (changed) are reprocessed.
- Setting `sqlmodded` to NULL for all rows then 1 only for modified rows prior to initiating a scan ensures precise changed tracking.

## Performance Characteristics
| Aspect | Behavior |
|--------|----------|
| I/O | Single pass SELECT; no file opens | 
| Memory | Holds a hash of all selected alib rows; consider streaming for >1M tracks (future enhancement) |
| CPU | Tag sanitation only; decoding/parsing skipped |
| Commit Strategy | Batches every 500 new or changed tracks (configurable in future) |

## Technical Metadata Handling
- `__bitspersample` → stored as LMS `samplesize` if not already set.
- Other numeric properties (`__channels`, `__frequency_num`, `__length_seconds`, etc.) are available to core tag handlers through the tag hash; ensure they exist in alib schema for LMS technical views.

## Contributor & Role Diagnostics (Debug Mode)
When `debugPlaceholders` is enabled:
- Fetches contributor rows for each processed track from LMS contributor tables.
- Logs anomalies (role mismatches, placeholder labels used in unexpected roles) when `anomalyChecksEnabled` is also on.
- Dumps tag contributor arrays vs DB contributor rows for correlation.

Turn off once baseline correctness is validated to avoid unnecessary queries.

## Deletion Handling
Tracks present in LMS but missing from alib (after cache load) are removed via `Slim::Utils::Scanner::Local::deleted`. Deletion progress uses its own progress instance with throttled updates.

## Error Handling & Fallbacks
- Column selection: If selective column prepare/execute fails, falls back to `SELECT * FROM alib`.
- Tag sanitation exceptions are caught and logged per track.
- Hook failure logs (missing alib row) are warnings, not fatal; track remains untouched if absence is unexpected.

## Troubleshooting
| Symptom | Possible Cause | Action |
|---------|----------------|--------|
| All tracks appear changed | `sqlmodded` set incorrectly | Verify only modified rows have `sqlmodded=1` |
| All tracks appear new | URL canonicalization mismatch | Confirm stored paths match `fixPath` output; adjust `_path` or filesystem case |
| Native scan still runs | Plugin not enabled or `alibdb` blank | Set both `enabled=1` and valid path; restart scan |
| Excessive logs | Debug prefs left on | Disable debug placeholders prefs |
| Missing technical fields | Column absent in alib schema | Add column / regenerate DB |

## Safe Disable / Revert
Uncheck "Enable Alib Scanning" and save. Plugin will restore `MediaFolderScan` importer. No track deletions occur solely due to disabling the plugin.

## Best Practices
- Keep an external process (TagMinder or equivalent) authoritative for tag updates; set `sqlmodded` on change.
- Run periodic integrity checks (outside LMS) to ensure `__path` uniqueness and case consistency.
- Avoid enabling verbose diagnostics in production for large libraries.

## Roadmap / Potential Enhancements
- Streaming ingestion (cursor processing) for multi-million track scalability.
- Optional column exclusion preference to reduce memory footprint.
- Adaptive commit batch sizing based on elapsed time.
- Precomputed contributor role lookup tables for micro-optimizations.
- SQLite PRAGMA tuning exposed via preferences.

## FAQ
**Q: Do I still need to keep audio files accessible to LMS?**  
A: LMS won't open them during ingest, but playback still requires accessible files.

**Q: What happens if a track exists in LMS but is removed from alib?**  
A: It's deleted during the deletion phase of the next scan.

**Q: Can I mix filesystem scanning with alib scanning?**  
A: Not recommended; the plugin deliberately disables native scanning to prevent conflicting metadata sources.

---

# Quick Start
1. Set path and enable plugin.
2. Mark changed rows with `sqlmodded=1`.
3. Trigger a rescan.
4. Verify counts (new + changed) align with expectations.
5. Disable debug prefs for production.

