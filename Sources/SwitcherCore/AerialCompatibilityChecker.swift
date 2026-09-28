import AVFoundation
import CoreMedia
import Foundation

public struct AerialCompatibilityReport {
    public let sampleCount: Int
    public let matchedTemporalSamples: Int
    public let duration: Double
    public let levels: Set<Int>
}

public struct AerialCompatibilityChecker {
    public init() {}

    public func check(_ movie: URL, expectedFrames: Int? = nil, expectedDuration: Double? = nil,
                      expectedWidth: Int? = nil, expectedHeight: Int? = nil,
                      ffmpeg: URL? = nil, cancellation: ConversionCancellation? = nil) throws -> AerialCompatibilityReport {
        let boxes = try BoxInventory(url: movie).temporalGroups()
        guard boxes.sgpd && boxes.csgm else { throw failure("缺少 sgpd(tscl) 或 csgm(tscl)") }
        let asset = AVURLAsset(url: movie)
        guard asset.isReadable, asset.isPlayable,
              let track = asset.tracks(withMediaType: .video).first,
              let format = track.formatDescriptions.first,
              CMFormatDescriptionGetMediaSubType(format as! CMFormatDescription) == 0x68766331 else {
            throw failure("MOV 不是可读取的 hvc1 HEVC 视频")
        }
        let details = try AVFoundationVideoInspector().inspect(movie)
        if let probe = FFmpegLocator.locateProbe() {
            let stream = try AerialMediaProbe.stream(movie, executable: probe)
            guard stream["codec_name"] as? String == "hevc",
                  stream["codec_tag_string"] as? String == "hvc1",
                  ["Main", "Main 10"].contains(stream["profile"] as? String ?? ""),
                  ["yuv420p", "yuv420p10le"].contains(stream["pix_fmt"] as? String ?? ""),
                  stream["color_range"] as? String == "tv",
                  stream["color_space"] as? String == "bt709",
                  stream["color_transfer"] as? String == "bt709",
                  stream["color_primaries"] as? String == "bt709" else {
                throw failure("HEVC profile、像素格式或 BT.709 limited 色彩标记不符")
            }
        }
        if let w = expectedWidth, details.width != w { throw failure("输出宽度不符合预期") }
        if let h = expectedHeight, details.height != h { throw failure("输出高度不符合预期") }
        if let duration = expectedDuration, abs(details.duration - duration) > 0.1 {
            throw failure("输出时长与源视频不符：\(details.duration) / \(duration)")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw failure("AVAssetReader 无法启动") }
        let levelKey = kCMSampleAttachmentKey_HEVCTemporalLevelInfo as String
        let temporalKey = kCMHEVCTemporalLevelInfoKey_TemporalLevel as String
        var count = 0, matched = 0, auxiliary = 0
        var levels = Set<Int>()
        var presentationTicks = Set<Int>()
        var firstPTS: Double?, lastPTS: Double?
        while let sample = output.copyNextSampleBuffer() {
            try cancellation?.requireActive()
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]] ?? []
            guard let block = CMSampleBufferGetDataBuffer(sample) else {
                if attachments.isEmpty { auxiliary += 1; continue }
                throw failure("视频帧缺少 NAL 数据")
            }
            var header = [UInt8](repeating: 0, count: 6)
            let result = header.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 6, destination: raw.baseAddress!)
            }
            guard result == noErr else { throw failure("样本无法读取 NAL") }
            let nalLength = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            let nalType = Int((header[4] >> 1) & 0x3f)
            if nalType > 31 { auxiliary += 1; continue }
            count += 1
            guard let info = attachments.first?[levelKey] as? [String: Any],
                  let level = info[temporalKey] as? Int, (0...4).contains(level) else {
                throw failure("视频帧 \(count) 缺少 temporal attachment")
            }
            guard nalLength >= 2, nalType <= 31, Int(header[5] & 7) - 1 == level else {
                throw failure("样本 \(count) 的 NAL temporal_id 与 Reader 附件不匹配")
            }
            matched += 1; levels.insert(level)
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard pts.isFinite else { throw failure("样本时间戳无效") }
            let tick = Int((pts * 240).rounded())
            guard abs(pts * 240 - Double(tick)) < 0.5,
                  presentationTicks.insert(tick).inserted else {
                throw failure("视频帧未按 240 fps CFR 时间轴排列（帧 \(count)，PTS \(pts)，tick \(tick)）")
            }
            firstPTS = min(firstPTS ?? pts, pts)
            lastPTS = max(lastPTS ?? pts, pts)
        }
        guard reader.status == .completed, count > 0, count == matched, auxiliary <= 16 else {
            let readerIssue = reader.error?.localizedDescription ?? String(localized: "未知错误")
            throw failure("Reader 未完整读取全部样本：\(readerIssue)")
        }
        if let expectedFrames, count != expectedFrames {
            throw failure("帧数不符：\(count) / \(expectedFrames)")
        }
        // The verified Writer uses a four-tick composition offset for B-frame reordering.
        guard presentationTicks == Set(4..<(count + 4)) else {
            let missing = Set(4..<(count + 4)).subtracting(presentationTicks).sorted().prefix(5)
            throw failure("240 fps 时间轴存在缺帧或额外时间偏移（\(count) 帧，tick \(presentationTicks.min() ?? -1)…\(presentationTicks.max() ?? -1)，缺少 \(Array(missing))）")
        }
        guard levels == [0, 1, 2, 3, 4] else { throw failure("未找到全部五层 temporal level") }
        guard (firstPTS ?? 1) < 0.1, abs((lastPTS ?? 0) + 1.0 / 240 - details.duration) < 0.1 else {
            throw failure("首尾时间戳与视频时长不一致")
        }
        if let ffmpeg {
            let task = Process(); let pipe = Pipe()
            task.executableURL = ffmpeg
            task.arguments = ["-hide_banner", "-v", "error", "-i", movie.path, "-map", "0:v:0", "-f", "null", "-"]
            task.standardOutput = Pipe(); task.standardError = pipe
            try cancellation?.track(task)
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            try cancellation?.requireActive()
            guard task.terminationStatus == 0 else {
                throw failure("完整解码失败：\(String(decoding: data.suffix(400), as: UTF8.self))")
            }
        }
        return .init(sampleCount: count, matchedTemporalSamples: matched, duration: details.duration, levels: levels)
    }

    private func failure(_ reason: LocalizedStringResource) -> SwitcherError {
        let explanation = String(localized: reason)
        return SwitcherError("转换结果未通过动态壁纸兼容性校验：\(explanation)。没有写入 manifest。")
    }
}

private struct BoxInventory {
    let url: URL
    func temporalGroups() throws -> (sgpd: Bool, csgm: Bool) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        var found = (sgpd: false, csgm: false)
        try walk(handle, start: 0, end: length, depth: 0, found: &found)
        return found
    }

    private func walk(_ handle: FileHandle, start: UInt64, end: UInt64, depth: Int,
                      found: inout (sgpd: Bool, csgm: Bool)) throws {
        guard depth < 9 else { return }
        var offset = start
        let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]
        while offset + 8 <= end {
            try handle.seek(toOffset: offset)
            guard let head = try handle.read(upToCount: 16), head.count >= 8 else { break }
            let size32 = u32(head, 0)
            let type = String(decoding: head[4..<8], as: UTF8.self)
            let header: UInt64 = size32 == 1 ? 16 : 8
            let size: UInt64 = size32 == 0 ? end - offset :
                size32 == 1 && head.count >= 16 ? u64(head, 8) : UInt64(size32)
            guard size >= header, size <= end - offset else { throw SwitcherError("MOV atom 结构损坏。") }
            if containers.contains(type) {
                try walk(handle, start: offset + header, end: offset + size,
                         depth: depth + 1, found: &found)
            } else if type == "sgpd" || type == "csgm" {
                try handle.seek(toOffset: offset + header)
                let first = try handle.read(upToCount: 8) ?? Data()
                if first.count == 8 && String(decoding: first[4..<8], as: UTF8.self) == "tscl" {
                    if type == "sgpd" { found.sgpd = true } else { found.csgm = true }
                }
            }
            offset += size
        }
    }

    private func u32(_ data: Data, _ offset: Int) -> UInt32 {
        data[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    private func u64(_ data: Data, _ offset: Int) -> UInt64 {
        data[offset..<offset + 8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}
