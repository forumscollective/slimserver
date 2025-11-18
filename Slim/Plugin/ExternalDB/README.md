# External Database Import Plugin - Reference Implementation

## Purpose

This plugin is a **reference implementation** that demonstrates the **CORRECT** way to integrate an external database (such as SQLite) with Lyrion Music Server without causing database corruption.

## ⚠️ Important: This is a Template

This plugin is:
- ✅ A working example of the correct pattern
- ✅ Heavily commented to explain the reasoning
- ✅ Disabled by default (it's not meant for production use as-is)
- ❌ NOT a complete, production-ready plugin
- ❌ NOT meant to be enabled without customization

## The Problem This Solves

Many developers try to create plugins that:
1. Read music metadata from an external database
2. Try to "intercept" or "prevent" scanner.pl from scanning the filesystem
3. Directly manipulate LMS's library.db tables

This approach **ALWAYS leads to database corruption** because:
- It bypasses LMS's transaction management
- It doesn't properly populate the `scanned_files` table
- It breaks the relationship between tracks, artists, albums, etc.
- It conflicts with LMS's AutoCommit=0 mode during scanning

## The Correct Solution

This plugin demonstrates the **correct pattern**:

1. **Use the Importer Interface**: Register with `Slim::Music::Import->addImporter()`
2. **Use `updateOrCreate()`**: This method handles ALL the complexity correctly
3. **Let LMS Manage Transactions**: Call `forceCommit()` periodically, but don't try to control transactions
4. **Work WITH the scanner**: Don't try to intercept or prevent it

## File Structure

```
Slim/Plugin/ExternalDB/
├── Plugin.pm          # Main plugin file, handles initialization and preferences
├── Importer.pm        # The importer that reads from external DB and imports tracks
├── install.xml        # Plugin metadata
├── strings.txt        # Localized strings
└── README.md          # This file
```

## How It Works

### Plugin.pm

- Initializes the plugin
- Manages preferences (enabled/disabled, database path)
- Registers the importer when enabled
- Triggers rescans when appropriate

### Importer.pm

This is where the magic happens:

1. **initPlugin()**: Registers the importer with LMS
2. **startScan()**: Called by scanner.pl during a scan
   - Connects to external database
   - Queries for track metadata
   - For each track:
     - Converts file path to URL
     - Builds metadata hash
     - Calls `Slim::Schema->updateOrCreate()`
   - Commits periodically with `forceCommit()`
   - Reports progress
   - Returns change count

### Why updateOrCreate() is Critical

The `Slim::Schema->updateOrCreate()` method (defined in Slim/Schema.pm):

- ✅ Checks if the file exists (unless you set checkMTime => 0)
- ✅ Updates the `scanned_files` table with correct timestamp and filesize
- ✅ Creates or updates the track in the `tracks` table
- ✅ Manages all relationships (artists, albums, genres, contributors, etc.)
- ✅ Handles change detection (if metadata changed)
- ✅ Respects the scanner's transaction management
- ✅ Can optionally read tags from the file (if readTags => 1)
- ✅ Returns a Track object or undef

If you bypass this method and try to INSERT directly into tables, you WILL get database corruption.

## Adapting This for Your Use Case

To use this as a template:

1. **Copy the plugin directory** to your own plugin name
2. **Rename the package** in Plugin.pm and Importer.pm
3. **Update the database connection** in Importer.pm to match your database
4. **Modify the SQL query** to match your table schema
5. **Map your fields** to the attributes hash
6. **Test with a small dataset** first
7. **Enable debug logging** and watch for errors

### Your External Database Schema

Your external database should have columns for:
- `file_path` (absolute path to the music file)
- `title`, `artist`, `album`, `genre` (basic metadata)
- `track_number`, `disc_number`, `year` (optional)
- `duration_seconds`, `bitrate`, `filesize` (file info)
- `modified_time` (Unix timestamp)
- Any other metadata you want to import

### Metadata Fields Supported

The attributes hash can include (from `Slim/Schema/Track.pm`):

- `TITLE` - Track title
- `ARTIST` - Artist name
- `ALBUMARTIST` - Album artist (if different from track artist)
- `ALBUM` - Album name
- `GENRE` - Genre
- `TRACKNUM` - Track number
- `DISC` - Disc number
- `DISCC` - Total disc count
- `YEAR` - Year
- `SECS` - Duration in seconds
- `BITRATE` - Bitrate in bits/second
- `FS` - File size in bytes
- `TIMESTAMP` - File modification time (Unix timestamp)
- `COMMENT` - Comment
- `COMPOSER` - Composer
- `CONDUCTOR` - Conductor
- `RATING` - Rating (0-100)
- `PLAYCOUNT` - Play count
- And many more...

See `Slim/Schema/Track.pm` for the complete list.

## Testing Your Implementation

1. **Start Small**: Test with 10-20 tracks first
2. **Enable Logging**:
   ```
   scanner.pl --rescan --debug plugin.yourname=debug
   ```
3. **Check Logs**: Look for errors in:
   - `scanner.log`
   - `server.log`
4. **Verify in UI**: Check that:
   - Tracks appear with correct metadata
   - Artists, albums, genres are populated
   - Album art displays (if provided)
   - Playlists work
5. **Test Scenarios**:
   - Full rescan: `scanner.pl --rescan`
   - Wipe and rescan: `scanner.pl --wipe --rescan`
   - Incremental updates (if your plugin supports it)
6. **Check Database**: No errors like "database is locked" or "database disk image is malformed"

## Common Mistakes to Avoid

### ❌ Directly Inserting into scanned_files

```perl
# WRONG - causes corruption
$dbh->do("INSERT INTO scanned_files ...");
```

### ❌ Trying to Intercept the Scanner

```perl
# WRONG - breaks scanner flow
no warnings 'redefine';
*Slim::Utils::Scanner::Local::find = sub { ... };
```

### ❌ Managing Transactions Manually

```perl
# WRONG - conflicts with scanner's transaction mode
$dbh->begin_work;
$dbh->commit;
```

### ❌ Directly Updating tracks Table

```perl
# WRONG - breaks relationships
$dbh->do("INSERT INTO tracks ...");
```

### ✅ The Correct Way

```perl
# CORRECT - handles everything
Slim::Schema->updateOrCreate({
    'url'        => $url,
    'attributes' => \%metadata,
    'readTags'   => 0,
    'checkMTime' => 0,
});
```

## Debugging Tips

Enable debug logging for your plugin:

```bash
# In scanner.pl
scanner.pl --rescan --debug plugin.yourname=debug

# Or via web UI
# Settings > Advanced > Logging
# Set plugin.yourname to DEBUG
```

Watch the logs:

```bash
tail -f /path/to/lms/Logs/scanner.log
tail -f /path/to/lms/Logs/server.log
```

Common issues:
- "File not found" - Check file paths are absolute and correct
- "Database is locked" - You're trying to manage transactions yourself
- "Malformed database" - You're directly manipulating tables
- Duplicate artists/albums - Metadata encoding or normalization issue

## Performance Considerations

- **Commit frequently**: Call `forceCommit()` every 5 seconds
- **Use prepared statements**: For your external DB queries
- **Batch reads**: Read many tracks at once from external DB
- **Progress reporting**: Update progress bar regularly
- **Check for aborts**: Honor `Slim::Music::Import->hasAborted()`

## Integration with LMS Features

Your imported tracks will automatically work with:
- ✅ Web UI browsing (artists, albums, genres)
- ✅ Players and remotes
- ✅ Playlists
- ✅ Search
- ✅ Random play
- ✅ Don't Stop the Music
- ✅ Favorites
- ✅ All other LMS features

As long as you use `updateOrCreate()`, everything just works!

## Real-World Examples

Study these production plugins for more examples:

- **Slim::Plugin::iTunes::Importer** - Imports from iTunes XML
  - Complex XML parsing
  - Handles playlists
  - Path normalization
  - Best overall example
  
- **Slim::Plugin::OnlineLibrary::Plugin** - Imports from online sources
  - Network-based metadata
  - Virtual tracks
  
- **Slim::Plugin::MusicMagic::Plugin** - Integrates with MusicIP
  - External program integration

## Support and Resources

- **Documentation**: See `/PLUGIN_EXTERNAL_DATABASE_GUIDE.md`
- **Source Code**: https://github.com/LMS-Community/slimserver
- **Forums**: https://forums.slimdevices.com
- **Wiki**: Various plugin development guides

## License

This example plugin follows the same license as Lyrion Music Server:
GNU General Public License version 2

## Summary

The key insight: **Work WITH LMS, not against it.**

Use the Importer interface and `updateOrCreate()` method, and let LMS handle the complex database management. This ensures your external database integrates cleanly without corruption.

Good luck with your plugin development!
