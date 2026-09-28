# Recovery and data boundaries

The App writes only to the current user's wallpaper data and its own Application Support directory. It stores original media and metadata for assets it owns, backs up the Aerial manifest before mutation, validates a temporary JSON file, and atomically replaces the live file. Localization changes similarly keep a complete user-side backup and verify the new table.

Normal App refresh does not restart `idleassetsd`. Keep a known-good backup before changing the user-side wallpaper catalog, especially after a macOS update.

If categories disappear after a system update or catalog refresh:

1. Stop further import or cleanup operations.
2. Make a separate copy of the current user-side manifest and localization bundle before recovery.
3. Compare category IDs and native assets with a known-good backup; preserve unrelated current entries.
4. Restore only the missing entries and matching localization data, then reparse the JSON and verify the file on disk.
5. Refresh only the current user's wallpaper extension, WallpaperAgent, and System Settings; verify the cards in Settings.

Do not copy a system manifest from a different macOS release without a careful diff.
