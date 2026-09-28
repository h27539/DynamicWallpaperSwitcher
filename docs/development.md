# Development

## Build and test

```sh
swift test --disable-sandbox
xcodebuild -project DynamicWallpaperSwitcher.xcodeproj \
  -scheme DynamicWallpaperSwitcher -configuration Release build
```

The Xcode Release target builds the SwiftUI App and `AerialMediaHelper`. Local build products are excluded by `.gitignore`. An ad-hoc signed local build can be verified with `codesign --verify --deep --strict <path-to-app>` after signing.

## Test boundaries

Fixture-based unit tests need no user wallpaper directory. Some conversion tests use external `ffmpeg`, `ffprobe`, or `x265`; they skip if the required tools are absent. The reference MOV compatibility test runs only when `DWS_TEST_MOV` points to a locally owned media file. The real Aerial card, lock-screen, and unlock checks are manual, local-only tests and must not run in public CI.

Do not commit local videos, Apple assets, full logs, manifest snapshots, or localization bundles. `tools/` contains parser and inspection source only.

## App icon

`Resources/AppIcon/icon.svg` and `generate_icon.swift` maintain the current static icon. Run the Swift generator to rebuild `master-1024.png`, then resize it into `DynamicWallpaperSwitcher.iconset` and `Assets.xcassets/AppIcon.appiconset`; compile the iconset with `iconutil`. The three simple SVGs in `Resources/AppIcon/Layers/` separate the frame, landscape, and play symbol for a future Icon Composer document. The checked-in `.icns` and asset catalog have a glass-like appearance, but they are static images: native, reactive Liquid Glass requires an Icon Composer file and appearance testing on macOS.
