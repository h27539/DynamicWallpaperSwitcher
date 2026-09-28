# Architecture

```text
SwiftUI App
  ├─ Tahoe / Golden Gate switcher → current-user NeptuneOne video container
  └─ Custom video import
       → ffmpeg / ffprobe → x265 five-layer HEVC encoder
       → AerialMediaHelper (CoreMedia attachments + AVAssetWriter)
       → AerialCompatibilityChecker
       → CustomAerialManager
       → current-user Aerial cache + manifest + localization
       → WallpaperAerialsExtension (system component)
```

`Sources/SwitcherCore` contains the switcher, conversion, compatibility, manifest, and localization logic. `Sources/DynamicWallpaperSwitcher` contains the SwiftUI app. `Sources/TemporalSampleWriterPOC` builds the helper used by the App; its historical name does not mean the Release App installs a POC card.

The converter streams frames and HEVC samples rather than expanding the full 240 fps video in memory. The compatibility checker must succeed before a new asset is installed. Manifest edits are scoped to the user directory and use backup, temporary JSON write, reparse, and atomic replacement. The app does not modify a system extension or `/System`.
