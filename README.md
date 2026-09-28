# DynamicWallpaperSwitcher

[English](#dynamicwallpaperswitcher) · [简体中文](docs/README.zh-CN.md)

Turn your own videos into native-style dynamic wallpapers for macOS. DynamicWallpaperSwitcher converts ordinary MOV or MP4 videos into Aerial-compatible HEVC wallpapers that play on the Lock Screen and transition to a still desktop image after unlocking.

> **Local 0.2.0 work in progress.** The public [v0.1.0 release](https://github.com/h27539/DynamicWallpaperSwitcher/releases/tag/v0.1.0) is still the Intel-only version. The Universal build in this source tree has not been published or tested on Apple Silicon hardware.

## Preview

Screenshot and demo recording will be added after final UI review. No Apple wallpaper video or artwork is included in this repository.

## Features

### Custom Dynamic Wallpapers

- Import a MOV or MP4 video and convert it to Aerial-compatible 10-bit HEVC.
- Play the result on the Lock Screen and retain a still desktop image after unlocking, as observed on the tested Intel Mac.
- Install your wallpaper into a dedicated **Custom / 自定义** category in System Settings → Wallpaper.
- Preserve the source aspect ratio, with output up to 3840 × 2160; standard CRF 17 and high-quality CRF 16 options.
- Optionally append a reversed copy of the video for a forward-and-back loop. The duplicate turnaround frames are removed, and reverse preparation uses temporary disk-backed chunks.
- Validate temporal sample mapping, 240 fps timing, HEVC decoding, and MOV sample groups before installation.
- Back up and validate current-user manifest and localization files before replacement; restore only App-owned assets.

### Apple Wallpaper Utilities

- Optionally switch the current user's Tahoe wallpaper provider resources between Tahoe and Golden Gate videos already present on the Mac.
- Keep the original Tahoe videos in a verified backup for restoration.
- Operate in the user's data only; no administrator privileges, `/System` writes, or SIP changes.

## Requirements and compatibility

| Platform | Status |
| --- | --- |
| macOS 26.7, Intel x86_64 | Tested on one Mac, including custom video playback and unlock transition |
| macOS 26.7, Apple Silicon arm64 | Universal build supported; runtime validation pending |
| Other macOS versions | Untested |

Conversion requires separately installed `ffmpeg`, `ffprobe`, and `x265`. For Homebrew users:

```sh
brew install ffmpeg x265
```

The App looks for standard Homebrew locations for either architecture and then searches `PATH`. The App does not bundle these tools. It displays the detected x265 binary architecture; an Intel build is not automatically rejected on Apple Silicon because Rosetta may run it. Actual execution errors are reported when conversion begins.

## Install and build

Download the current public [v0.1.0 release](https://github.com/h27539/DynamicWallpaperSwitcher/releases/tag/v0.1.0) for Intel, or build the local 0.2.0 source with Xcode:

```sh
git clone https://github.com/h27539/DynamicWallpaperSwitcher.git
cd DynamicWallpaperSwitcher
xcodebuild -project DynamicWallpaperSwitcher.xcodeproj \
  -scheme DynamicWallpaperSwitcher -configuration Release \
  -arch x86_64 -arch arm64 ONLY_ACTIVE_ARCH=NO build
```

Both the main App and `AerialMediaHelper` should contain x86_64 and arm64 slices. The local build is ad-hoc signed, not notarized. macOS may ask you to approve opening it. A local development build is not a published release.

## Use

1. Open **Custom Dynamic Wallpapers**. Confirm that `ffmpeg`, `ffprobe`, and `x265` are found.
2. Choose **Add Video**, select a MOV or MP4, choose standard or high quality, and optionally enable **Play forward, then reverse**.
3. Wait for conversion and compatibility checks to finish. The App keeps the source video intact.
4. Open **System Settings → Wallpaper → Custom / 自定义** and select the new wallpaper.
5. Use **Apple Wallpaper Utilities** only if you also want to switch between Tahoe and Golden Gate resources.

Current limits: limited-range SDR input tagged BT.709, SMPTE 170M, or BT.470BG, videos up to four minutes, and output up to 3840 × 2160. The forward-and-reverse option needs a constant-frame-rate source with readable frame count and a result no longer than four minutes; it takes extra time and temporary disk space. Supported SD color combinations are converted to BT.709 before encoding. HDR, BT.2020, and full-range sources are rejected. Longer videos and other macOS versions need separate validation. 4K conversion can take several minutes.

## Tahoe / Golden Gate utility

Tahoe and Golden Gate are Apple-provided dynamic wallpaper assets from different macOS generations. On systems with native support, macOS manages them. The optional utility here switches the current user's video resources used by the existing Apple wallpaper provider on a compatible Mac. It does not add a new system provider or modify system files.

The repository and App **do not provide or download Apple video assets**. You must already have the corresponding assets available through your own macOS installation or account. The custom-video workflow does not need Golden Gate assets.

## How it works and safety

The converter creates a 240 fps HEVC timeline with five x265 temporal layers and matching CoreMedia sample attachments. AVAssetWriter produces the `sgpd/csgm(tscl)` sample groups required by the tested Aerials path. The compatibility checker verifies the MOV before an atomic user-side manifest update. Details: [architecture](docs/architecture.md) and [recovery](docs/recovery.md).

Only current-user wallpaper data is changed. The App makes verified backups, validates temporary writes and JSON, and restricts deletion to App-owned UUIDs. It does not restart `idleassetsd` during wallpaper refresh. Apple's Aerial manifest behavior is undocumented and may change after a macOS update. Recovery steps are in [recovery](docs/recovery.md).

## Development and license

See [development](docs/development.md), [contributing](CONTRIBUTING.md), and [third-party notices](THIRD_PARTY_NOTICES.md). Source code is [MIT licensed](LICENSE), Copyright (c) 2026 h27539. FFmpeg and x265 have their own licenses; HEVC may carry separate patent or licensing obligations. This is an unofficial community project and is not affiliated with Apple. No proprietary Apple artwork or videos are distributed here.
