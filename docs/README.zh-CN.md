# DynamicWallpaperSwitcher

[English](../README.md) · 简体中文

把自己的普通视频转换成 macOS 原生风格的动态壁纸。导入 MOV 或 MP4 后，App 会生成与实测 Aerials 路径兼容的 HEVC 视频；锁屏时播放，解锁后停留在桌面静态画面。

> 当前仓库本地正在准备 0.2.0。公开的 [v0.1.0](https://github.com/h27539/DynamicWallpaperSwitcher/releases/tag/v0.1.0) 仍是 Intel 版本。本地 Universal 构建尚未发布，也未在 Apple Silicon 实机验收。

## 主要功能：自定义动态壁纸

1. 在 App 的“自定义动态壁纸”页点击“添加视频”，选择 MOV 或 MP4。
2. 选择标准（CRF 17）或高质量（CRF 16）；若想让画面往返循环，可勾选“正放后倒放（首尾相接）”，再等待转换与兼容性检查。
3. 打开“系统设置 → 墙纸 → 自定义”，选择新增壁纸。

转换使用 10-bit HEVC、240 fps 时间轴和五层 temporal hierarchy。安装前会检查视频解码、时间戳、temporal 映射和 MOV 样本组。输出最高 3840 × 2160，保留输入宽高比。App 会备份并验证用户目录里的清单和本地化资源，仅清理自己记录的 UUID。

## 附加功能：Apple 墙纸工具

Tahoe 与 Golden Gate 是不同 macOS 世代提供的 Apple 动态墙纸资源。对于无法原生使用新版墙纸、但已在本机拥有相应视频素材的 Mac，这个附加工具可以切换当前用户的现有墙纸 provider 所用的视频。它不修改系统文件，也不关闭 SIP。

本项目**不提供、不下载 Apple 的墙纸视频或专有素材**。自定义视频功能不依赖 Golden Gate 素材。

## 环境与安装

需要 macOS、Xcode（从源码构建时），以及独立安装的 `ffmpeg`、`ffprobe`、`x265`。使用 Homebrew 可运行：

```sh
brew install ffmpeg x265
```

App 会自动检查 Intel 与 Apple Silicon 常见安装位置及 `PATH`，无需手工选择 Homebrew 目录。构建命令：

```sh
xcodebuild -project DynamicWallpaperSwitcher.xcodeproj \
  -scheme DynamicWallpaperSwitcher -configuration Release \
  -arch x86_64 -arch arm64 ONLY_ACTIVE_ARCH=NO build
```

本地构建为临时签名，尚未公证。系统可能要求用户手动批准打开。

## 兼容性

| 平台 | 状态 |
| --- | --- |
| macOS 26.7 Intel | 已在一台 Mac 实测自定义视频、锁屏播放和解锁过渡 |
| macOS 26.7 Apple Silicon | Universal 构建支持，实机运行仍待验证 |
| 其他 macOS 版本 | 未测试 |

目前支持标记为 BT.709、SMPTE 170M 或 BT.470BG 的 SDR、limited range 输入，最多四分钟。往返模式要求能确认帧数的固定帧率视频，往返成片也不能超过四分钟；准备倒放会额外占用时间和临时磁盘空间。受支持的标清色彩组合会先转换到 BT.709 再编码。HDR、BT.2020 和 full range 会被拒绝。长视频和其他 macOS 版本仍需另行验证；4K 转换可能耗时数分钟。

## 安全与恢复

仅修改当前用户的墙纸数据；无需管理员权限，不写入 `/System`，不改变 SIP/SSV。清单和本地化资源写入前会备份并校验，使用临时文件与原子替换。macOS 更新可能改变未公开的 Aerials 行为。详见[恢复说明](recovery.md)和[架构](architecture.md)。

## 许可证

项目代码采用 [MIT](../LICENSE) 许可证，Copyright (c) 2026 h27539。FFmpeg、x265 和 HEVC 相关权利分别适用其许可或法律要求，详见[第三方说明](../THIRD_PARTY_NOTICES.md)。本项目与 Apple 无隶属或背书关系，也不分发其专有壁纸视频或图像。
