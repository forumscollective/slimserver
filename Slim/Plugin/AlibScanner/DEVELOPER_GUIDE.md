# AlibScanner Developer Guide

## Purpose
AlibScanner substitutes LMS's filesystem scanning pipeline with metadata ingestion exclusively from an external SQLite database ("alib"). This guide documents architecture, data flow, extension points, and performance considerations to aid maintenance and future enhancements.

## High-Level Architecture
Component | Responsibility
---------|---------------
`Plugin.pm` | Registers importer, manages enable/disable lifecycle, toggles native `MediaFolderScan` importer.
`Importer.pm` | Core ingestion: loads alib rows, classifies new/changed/deleted, creates/updates LMS Track records, hooks tag access.
`Settings.pm` | Exposes preferences in Web UI; defines editable prefs list.
`strings.txt` | Localized strings for UI labels/descriptions.
`basic.html` | Web UI settings template (Enable, DB path, debug toggles).

### Importer Flow (Simplified)
1. `initPlugin` -> `init()` (server & scanner) -> registers importer with weight 0; disables native importer if enabled.
2. `Importer->scan()` (via LMS Import framework) -> `_installHooks()` ensures tag/scan hooks are active.
3. `_loadAlibCache` performs dynamic column selection using `PRAGMA table_info(alib)`; builds `%alibCache` keyed by canonical URL.
4. `_processAllTracks`:
   - Preload existing track URLs from LMS DB (canonicalized).
   - Classify URLs (new vs changed via `sqlmodded > 0`).
   - For new: call `updateOrCreateBase(readTags => 1, new => 1)`; for changed: `updateOrCreateBase(readTags => 1)`.
   - Populate technical metadata (`samplesize`) if available.
   - Optional instrumentation (contributors, album diagnostics) gated by debug prefs.
   - Deletion pass removes LMS tracks absent in alib.
5. Hooks override file/tag access so `Audio::Scan::scan` and `Slim::Formats::readTags` return alib-derived tags.

## Hooks & Overrides
Hooked Function | Original Behavior | New Behavior
----------------|-------------------|--------------
`Audio::Scan::scan($file)` | Reads file bytes, parses format-specific tags | Returns `{ tags => ..., audio => ... }` from alib row; skips disk I/O.
`Slim::Formats::readTags($url)` | Delegates to format-specific tag readers | Returns sanitized `tags` from alib cache.

Hook installation is guarded by `_installHooks()` with a `redefine` warning suppression. Removal via `_removeHooks()` (invoked when disabling plugin) should restore original code references (declared but needs review if expansion required).

## Preferences & Instrumentation
Preference | Code Path Influence
----------|---------------------
`enabled` | Plugin activation, importer registration.
`alibdb` | Source DB path; required to proceed.
`debugPlaceholders` | Enables contributor & album diagnostic queries and trace logging.
`debugPlaceholdersVerbose` | Adds high-volume MBID and contributor tag dumps.
`anomalyChecksEnabled` | Enables anomaly-specific conditional blocks inside contributor iteration.

Instrumentation macros (log tags): `ALBUMTRACE`, `PLACEHOLDERTRACE`, `COMPOSER_ANOMALY`, `TRACKCONTRIBTRACE`, `READTAGSTRACE`, `MBIDTRACE`.

## Data Structures
Name | Type | Purpose
-----|------|--------
`%alibCache` | Hash (URL => row hashref) | In-memory snapshot of selected columns for all tracks.
`%existing` | Hash (URL => 1) | Fast membership test for new vs existing track classification.
`@newUrls` / `@changedUrls` | Arrays | Worklists for creation/update phases.
`%albumSeen` | Hash (AlbumID => count) | Diagnostic only; gated by debug.
`%STH_CACHE` | Hash (SQL => DBI::st handle) | Statement handle cache to avoid repeated prepare.

## Column Selection Logic
- Desired column list enumerated in `@wanted`.
- `PRAGMA table_info(alib)` yields existing columns; wanted list filtered to present subset.
- Fallback: if selective prepare or execute fails, revert to `SELECT * FROM alib`.
- Missing columns logged once for operator awareness.

## Change Detection
Criterion | Implementation
----------|---------------
New track | URL absent in `%existing` (post-canonicalization).
Changed track | Row has `sqlmodded > 0`.
Deleted track | LMS URL not present in `%alibCache`.

Composer-delta logic was removed to rely solely on authoritative external change flag (`sqlmodded`).

## Track Creation & Update
Call: `Slim::Schema->updateOrCreateBase({ url => $url, readTags => 1, new => 1/undef, checkMTime => 0, commit => 0 })`
Behavior: LMS will invoke our overridden tag readers due to `readTags => 1`; file mtime check skipped.
Commit Strategy: Manual commit every 500 processed items to reduce transaction overhead and memory inflation.

## Technical Tag Handling
- Bit depth: `__bitspersample` -> `samplesize` column if not set.
- Other fields remain accessible through tag sanitation path; ensure alib rows map names expected by LMS.

## Performance Considerations
Area | Current Approach | Potential Enhancement
-----|------------------|----------------------
Memory | Full cache of all rows | Streaming cursor ingestion (chunk + process) with sparse retention.
DB Access | Single SELECT pass; cached prepared statements for frequent lookups | Add persistent connection pooling if external wrapper used.
Commit Batch | Fixed 500 | Adaptive based on time or track size distribution.
Diagnostics | Gated; removed overhead when disabled | Separate lightweight counters vs full queries.

## Error & Fallback Strategy
Scenario | Handling
---------|---------
Selective query prepare failure | Log error; fallback to `SELECT *`.
Selective query execute failure | Log error; fallback to `SELECT *`.
Tag sanitation exception | Warn; continue processing.
Missing row on tag read | Return empty hash; skip instrumentation.
Hook removal errors | Logged but non-fatal on disable.

## Extension Points
Goal | Suggested Approach
---- | ------------------
Add new metadata fields | Extend `@wanted` list; adapt tag sanitation mapping if necessary.
Expose batch size preference | Add to `Settings.pm` prefs list & settings template; use in commit modulus.
Add streaming ingestion | Replace cache build with iterator; maintain diff classification via prefetch index or separate changed table.
Add column exclusion prefs | Compute dynamic `@wanted` minus user-excluded list before PRAGMA filter.
Add PRAGMA tuning | Execute recommended PRAGMAs after DB connect when enabled (eg. `journal_mode=WAL`).
Add contributor cache | Preload role maps into memory keyed by contributor ID to reduce per-track queries.

## Logging Conventions
Level | Use
------|----
`error` | Forced visibility for diagnostics & summary metrics (ALBUMTRACE, PLACEHOLDERTRACE). Consider migrating non-error diagnostics to `info`/`debug`.
`warn` | Recoverable anomalies (sanitization errors, hook removal failure).
`info` | Startup, registration, skipping absent columns output.

Refinement opportunity: reduce use of `error` level for routine instrumentation when debug prefs active to avoid confusion in production logs.

## Testing Strategy (Recommended)
Test | Description
-----|------------
Baseline ingest | Load small alib DB; verify counts (new vs changed vs deleted) match DB row state.
Change flag update | Flip subset `sqlmodded` values; run changed scan; confirm only flagged tracks reprocessed.
Disable plugin | Toggle `enabled` off; ensure native scan resumes and hooks removed.
Large library simulation | Use synthetic alib table with >100k rows; measure memory and ingestion time.
Diagnostics gating | Enable each debug pref individually; verify additional queries only occur when expected.
Fallback path | Temporarily force selective query failure; confirm fallback to `SELECT *` and accurate track creation.

## Security & Safety Notes
- The plugin trusts file paths from the alib DB; ensure upstream process validates and normalizes paths to prevent directory traversal misuse (playback layer still enforces real file existence).
- No SQL user input concatenation except dynamic column list (which is built from schema names, not external untrusted input). Low injection risk; maintain whitelist pattern if adding user-provided filtering.

## Code Navigation Reference
Function / Variable | Location | Purpose
-------------------|----------|--------
`initPlugin` | `Plugin.pm` | Entry point; registers importer and settings.
`init` | `Plugin.pm` | Enable logic; importer registration & native scan disable.
`_disableAlibScanner` | `Plugin.pm` | Cleanup on preference flip.
`_loadAlibCache` | `Importer.pm` | Load rows; selective column selection & fallback.
`_processAllTracks` | `Importer.pm` | Classification and ingestion loop.
`_installHooks` | `Importer.pm` | Override tag/file access.
`_getAlibMetadata` | `Importer.pm` | Build tag + audio hash per track.
`_cached_sth` & `%STH_CACHE` | `Importer.pm` | Prepared statement caching.
`Settings.pm::prefs` | `Settings.pm` | Exposes editable preferences.

## Deployment & Upgrade Notes
- Schema changes: Add new columns to alib DB first; plugin auto-detects presence—no code change required unless logic depends on new fields.
- Preference additions: Update `Settings.pm`, `basic.html`, and `strings.txt` for localization.
- Backward compatibility: Keep importer weight lower than native (0 vs 1) to ensure execution precedence.

## Roadmap Ideas (Detailed)
Enhancement | Outline
-----------|--------
Streaming ingestion | Use `DBI->prepare('SELECT ...')` + `fetchrow_hashref` per batch; remove global cache; classification: maintain separate `changed` table or track-level delta table.
Adaptive commit | Track time elapsed per 500 batch; if > threshold, reduce batch size; else increase—store in preference.
Index recommendation tool | Query SQLite `sqlite_master` for existing indexes; suggest CREATE INDEX commands for frequently filtered columns (`sqlmodded`, `__path`). Provide optional script output.
Contributor role cache | Preload contributor_role mapping once; reuse for anomaly checks to avoid per-track extra queries.
PRAGMA tuning preference | Add toggles for WAL & synchronous modes; apply at importer init when enabled.

## Common Pitfalls
Pitfall | Avoidance
--------|----------
Incorrect path case | Ensure TagMinder / upstream process preserves original case; rely on consistent `fixPath` normalization.
sqlmodded not reset | Always reset to NULL before bulk updates then set to 1 where changed for accurate delta classification.
Leaving debug on | Disable debug prefs after validation to minimize overhead.
Overusing error log level | Prefer `info` for high-volume internal metrics.

## Contributing Guidelines
1. Keep changes isolated to plugin namespace; avoid modifying core LMS modules unless explicitly approved.
2. Preserve fallback behavior for column selection and tag reading.
3. Gate all new instrumentation behind preferences.
4. Add tests (where possible) or manual verification notes for performance-impacting changes.
5. Use `_cached_sth` for any repeated SQL.

## Glossary
Term | Definition
-----|-----------
Alib | External SQLite metadata database containing per-track rows.
Canonical URL | Normalized track path using LMS's `fixPath` function.
`sqlmodded` | Integer column indicating externally flagged changes (1 = changed, NULL = unchanged).
Instrumentation | Optional diagnostic logging for contributors and album relationships.

## Quick Dev Checklist
- [ ] Added new preference to `Settings.pm`, `basic.html`, `strings.txt`.
- [ ] Guarded optional logic behind preference.
- [ ] Utilized `_cached_sth` for repeated queries.
- [ ] Updated user guide if user-facing behavior changed.
- [ ] Verified no unintended core module edits.

---

