# DynamicWallpaperSwitcher

A macOS utility for switching Tahoe and Golden Gate wallpaper assets and converting personal videos into Aerial-compatible dynamic wallpapers.

> v0.1.0 is a tested baseline on one Intel Mac running macOS 26.7. Apple Silicon and other macOS versions have not been verified.

## Features

- Switch the user-side NeptuneOne video assets between Tahoe and locally available Golden Gate assets.
- Convert a personal SDR video into a five-layer HEVC Aerial asset with native lock-screen playback and desktop transition on the tested Mac.
- Add converted videos to a dedicated “Custom” category in Wallpaper settings.
- Validate the converted MOV before installing its Aerial cache and manifest entry.
- Back up and validate user-side manifest and localization changes; restore owned assets without touching unrelated entries.

## Demo

A real screen recording is planned at `docs/demo.gif`. No screenshot or video is included in this repository.

## Requirements and compatibility

| Environment | Status |
| --- | --- |
| macOS 26.7 on Intel Mac | Tested with the source and workflow described in [validation](docs/validation.md) |
| Apple Silicon | Untested |
| Other macOS versions | Untested |

Build with Xcode and the macOS SDK. Video conversion calls external `ffmpeg`, `ffprobe`, and `x265` executables; x265 4.1 was tested. One way to install them is:

```sh
brew install ffmpeg x265
```

Homebrew is optional; binaries installed another way may also work if the App can locate them. The repository and App do not bundle those executables.

## Installation and building

The [v0.1.0 release](https://github.com/h27539/DynamicWallpaperSwitcher/releases/tag/v0.1.0) offers an Intel-only, ad-hoc signed App ZIP. The App and bundled helper are x86_64; Apple Silicon use has not been validated. The ZIP does not include FFmpeg, ffprobe, x265, or Apple wallpaper videos.

Build from source:

```sh
git clone https://github.com/h27539/DynamicWallpaperSwitcher.git
cd DynamicWallpaperSwitcher
open DynamicWallpaperSwitcher.xcodeproj
```

Select the `DynamicWallpaperSwitcher` scheme and build the Release configuration. A command-line build is also possible:

```sh
xcodebuild -project DynamicWallpaperSwitcher.xcodeproj \
  -scheme DynamicWallpaperSwitcher -configuration Release build
```

A locally built `.app` is not tracked in Git. The v0.1.0 downloadable App, if published, is an Intel (`x86_64`) build; Apple Silicon use has not been tested.

## Usage

1. Open the App and check the external tool status.
2. To import a personal wallpaper, choose **添加视频**, then select standard or high quality.
3. Wait for conversion and compatibility validation to complete.
4. Open **System Settings → Wallpaper** and select the new card in **Custom / 自定义**.
5. For Tahoe ↔ Golden Gate switching, use the separate switcher controls. Golden Gate requires suitable Apple video assets already available on your own Mac. This project does not download or provide those videos.

## How it works

The custom-video path turns source frames into a 240 fps HEVC timeline with five x265 temporal layers. It writes matching CoreMedia temporal sample attachments through AVAssetWriter, producing `sgpd/csgm(tscl)` sample-group information. The compatibility checker then verifies the MOV structure, timestamps, full-sample temporal mapping, and decoding before a user-side Aerial manifest update. See [architecture](docs/architecture.md) and [format notes](docs/aerial-format-notes.md).

The Tahoe switcher operates on video assets in the current user's NeptuneOne container. The custom-video path operates on the current user's Aerials cache, manifest, and App support directory.

## Limitations

- HDR, BT.2020, and full-range inputs are currently rejected.
- The tested full video was about 22 seconds. Longer videos and more source formats need validation.
- Conversion requires separately installed command-line tools and can take several minutes at 4K.
- Apple's Aerial manifest and provider behavior are undocumented implementation details. A macOS update may change them.
- The v0.1.0 Intel App is ad-hoc signed but not notarized. macOS may require the user to approve opening it. Apple Silicon use has not been tested.

## Safety and recovery

No administrator access, `/System` edits, or SIP/SSV changes are required. The App modifies only current-user wallpaper data. It backs up and validates the manifest and localization data before changes, writes via temporary files and atomic replacement, and limits deletion to App-owned UUIDs. The App does not restart `idleassetsd` during wallpaper refresh. See [recovery](docs/recovery.md).

## Development

See [development](docs/development.md), [validation](docs/validation.md), and [contributing](CONTRIBUTING.md). The full local research report and media fixtures are intentionally excluded from Git.

## License and third-party software

Project code is licensed under [MIT](LICENSE), Copyright (c) 2026 h27539. FFmpeg and x265 are external tools under their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). HEVC/H.265 may be subject to patent or licensing requirements in some jurisdictions. Users and distributors should evaluate applicable requirements.

## Disclaimer

This is an unofficial community project, not affiliated with or endorsed by Apple Inc. macOS, Tahoe, and other Apple product names are trademarks of Apple Inc. This repository does not distribute Apple's wallpaper video assets. Users must obtain and use system-provided assets on their own devices.
