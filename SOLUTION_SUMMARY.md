# Solution Summary: External Database Plugin Database Corruption

## Problem Statement

A user reported that their plugin, which uses an external SQLite database (alib) to provide music library information, was causing corruption of Lyrion Music Server's `library.db` and `persist.db` files. The plugin attempted to intercept `scanner.pl` to prevent filesystem access and provide file lists and metadata directly.

## Root Cause

The corruption was caused by attempting to bypass or intercept the scanner instead of working with it through the proper APIs. Common mistakes that cause this issue:

1. **Directly manipulating database tables**: Inserting into `scanned_files` or `tracks` tables
2. **Bypassing the Importer interface**: Trying to hook or intercept scanner methods
3. **Managing transactions manually**: Setting AutoCommit or using BEGIN/COMMIT
4. **Not using the official API**: Avoiding `Slim::Schema->updateOrCreate()`

## Solution Provided

### 1. Comprehensive Documentation

**File: PLUGIN_EXTERNAL_DATABASE_GUIDE.md**

A complete guide explaining:
- Why database corruption occurs
- The correct approach using the Importer interface
- How `updateOrCreate()` works internally
- Step-by-step implementation pattern
- Common pitfalls to avoid
- Testing strategies

### 2. Reference Implementation

**Directory: Slim/Plugin/ExternalDB/**

A fully functional example plugin demonstrating the correct pattern:

- **Plugin.pm**: Shows how to initialize and register the importer
- **Importer.pm**: Complete working example with extensive comments explaining:
  - How to register with `addImporter()`
  - How to connect to external database
  - How to query external data
  - How to convert to LMS format
  - How to use `updateOrCreate()` correctly
  - How to handle progress and commits
- **README.md**: Detailed explanation of the implementation
- **install.xml**, **strings.txt**: Standard plugin metadata

### 3. Automated Validation

**File: t/validate_external_db_plugin.t**

A test suite that validates:
- All plugin files exist
- Plugin uses correct patterns (`addImporter`, `updateOrCreate`, `forceCommit`)
- Plugin avoids anti-patterns (direct table manipulation)
- Documentation is comprehensive

All 15 tests pass ✅

## The Correct Pattern

```perl
# 1. Register the importer
Slim::Music::Import->addImporter($class, {
    'type'   => 'file',
    'weight' => 20,
    'use'    => $enabled,
});

# 2. In startScan(), read from external DB
sub startScan {
    my $ext_dbh = DBI->connect("dbi:SQLite:dbname=$external_db");
    my $sth = $ext_dbh->prepare("SELECT * FROM alib");
    
    while (my $row = $sth->fetchrow_hashref()) {
        my $url = Slim::Utils::Misc::fileURLFromPath($row->{file_path});
        
        # 3. Use updateOrCreate - this is THE critical method
        Slim::Schema->updateOrCreate({
            'url'        => $url,
            'attributes' => \%metadata,
            'readTags'   => 0,
            'checkMTime' => 0,
        });
        
        # 4. Commit periodically
        if (time() > $lastCommit + 5) {
            Slim::Schema->forceCommit;
            $lastCommit = time();
        }
    }
}
```

## Why This Works

### updateOrCreate() Handles Everything

The `Slim::Schema->updateOrCreate()` method automatically:
1. ✅ Checks if the track exists
2. ✅ Populates `scanned_files` table correctly
3. ✅ Creates/updates track in `tracks` table
4. ✅ Manages all relationships (artists, albums, genres)
5. ✅ Handles change detection
6. ✅ Respects scanner's transaction management
7. ✅ Can optionally read file tags if needed
8. ✅ Returns a Track object or undef

### Works WITH the Scanner

Instead of trying to prevent or bypass the scanner:
- The importer is called BY the scanner as part of normal flow
- LMS manages the database transaction state (AutoCommit=0)
- `forceCommit()` is used periodically, but LMS controls overall flow
- All LMS features work normally (web UI, search, playlists, etc.)

## Benefits

1. **No Database Corruption**: Using official APIs prevents corruption
2. **Full Integration**: All LMS features work automatically
3. **Maintainable**: Following standard patterns means updates won't break
4. **Tested Pattern**: Same approach used by iTunes, OnlineLibrary plugins
5. **Clear Documentation**: Heavily commented example code explains everything

## For Plugin Developers

To adapt this for your use case:

1. Copy the `Slim/Plugin/ExternalDB` directory
2. Rename the package/files to your plugin name
3. Update the database connection to your external database
4. Modify the SQL query to match your schema
5. Map your fields to the attributes hash
6. Test with a small dataset first
7. Run the validation tests

## Key Takeaway

**Work WITH LMS, not against it.**

Use the Importer interface and `updateOrCreate()` method. Don't try to intercept, bypass, or directly manipulate the scanner or database tables. This ensures clean integration without corruption.

## Files Modified/Added

1. `PLUGIN_EXTERNAL_DATABASE_GUIDE.md` - Comprehensive guide (new)
2. `Slim/Plugin/ExternalDB/Plugin.pm` - Plugin main file (new)
3. `Slim/Plugin/ExternalDB/Importer.pm` - Importer implementation (new)
4. `Slim/Plugin/ExternalDB/install.xml` - Plugin metadata (new)
5. `Slim/Plugin/ExternalDB/strings.txt` - Localized strings (new)
6. `Slim/Plugin/ExternalDB/README.md` - Plugin documentation (new)
7. `t/validate_external_db_plugin.t` - Automated tests (new)
8. `SOLUTION_SUMMARY.md` - This file (new)

## Testing

Run the validation test:
```bash
perl t/validate_external_db_plugin.t
```

All tests pass with this implementation.

## References

- **Slim::Plugin::iTunes::Importer** - Production example of external import
- **Slim::Music::Import** - Import system documentation
- **Slim::Schema** - Database schema and updateOrCreate() method
- **Slim::Utils::Scanner::API** - Scanner hooks for plugins

## Support

For questions or issues:
- Review the comprehensive guide: `PLUGIN_EXTERNAL_DATABASE_GUIDE.md`
- Study the example plugin: `Slim/Plugin/ExternalDB/`
- Check the iTunes plugin for a production example
- Post on Lyrion forums: https://forums.slimdevices.com

---

This solution provides everything needed to correctly implement an external database plugin without causing database corruption.
