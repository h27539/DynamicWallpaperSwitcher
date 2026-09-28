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

`Resources/AppIcon/AppIcon.icon` is the editable Icon Composer document used by the Xcode target. Its `Assets/` directory contains the frame, landscape, and play layers. Edit the document in Icon Composer, save it in place, and rebuild; Xcode compiles the `AppIcon` icon into the App's asset catalog and generates a compatibility `.icns` for macOS. The older `icon.svg`, `generate_icon.swift`, `.iconset`, `.icns`, and `Assets.xcassets/AppIcon.appiconset` are retained as source/fallback artwork, but the explicit legacy `.icns` bundle override has been removed. Check the rendered icon in light and dark appearance after changing layers.
