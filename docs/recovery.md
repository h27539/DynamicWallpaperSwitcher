# Recovery and data boundaries

The App writes only to the current user's wallpaper data and its own Application Support directory. It stores original media and metadata for assets it owns, backs up the Aerial manifest before mutation, validates a temporary JSON file, and atomically replaces the live file. Localization changes similarly keep a complete user-side backup and verify the new table.

A Mac category disappearance was observed after a POC cleanup run on the tested host. The live manifest had been replaced by an older catalog lacking Mac entries. Restarting `idleassetsd` was temporally associated with that replacement, but the available logs did not establish a unique cause. Normal App refresh therefore no longer restarts `idleassetsd`. The cleanup path also checks that the native Mac category and Mac Blue entry exist before acting.

If categories disappear after a system update or catalog refresh:

1. Stop further import or cleanup operations.
2. Make a separate copy of the current user-side manifest and localization bundle before recovery.
3. Compare category IDs and native assets with a known-good backup; preserve unrelated current entries.
4. Restore only the missing entries and matching localization data, then reparse the JSON and verify the file on disk.
5. Refresh only the current user's wallpaper extension, WallpaperAgent, and System Settings; verify the cards in Settings.

The original incident-specific recovery script and real manifest snapshots are not part of the public repository because they contain machine-specific IDs, paths, and user data. Do not copy a system manifest from a different macOS release without a careful diff.
