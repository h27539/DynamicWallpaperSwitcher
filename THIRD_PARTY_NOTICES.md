# Third-party notices

This repository and the built App do not contain FFmpeg, ffprobe, or x265 source code or binaries. The App invokes separately installed command-line executables via `Process`.

| Tool | Use | Licensing information |
| --- | --- | --- |
| FFmpeg / ffprobe | Decode, inspect, and prepare source video | FFmpeg is generally LGPL 2.1 or later; optional build components can make a particular build GPL. The exact terms depend on the binary installed by the user. See [FFmpeg's license guidance](https://ffmpeg.org/legal.html). |
| x265 | Encode five temporal HEVC layers | x265 is offered under GNU GPL v2 or later and a commercial license. See the [upstream project](https://github.com/videolan/x265) and its [license file](https://github.com/videolan/x265/blob/master/COPYING). |

This project's MIT license covers only its own code. It does not relicense external tools, Apple's frameworks or assets, or media supplied by users. HEVC/H.265 may be subject to patent or licensing requirements in some jurisdictions; users and distributors are responsible for evaluating applicable requirements. This document is not legal advice.
