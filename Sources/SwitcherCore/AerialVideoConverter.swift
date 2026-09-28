import AVFoundation
import CoreMedia
import Foundation

public enum QualityPreset: String, CaseIterable, Identifiable {
    case standard, high
    public var id: String { rawValue }
    public var crf: Int { self == .standard ? 17 : 16 }
    public var label: String { self == .standard ? "标准 · CRF 17" : "高质量 · CRF 16" }
}

public struct ConversionOptions {
    public let quality: QualityPreset
    public let pingPong: Bool
    public init(quality: QualityPreset = .standard, pingPong: Bool = false) {
        self.quality = quality
        self.pingPong = pingPong
    }
}

public struct ConversionProgress {
    public let stage: String
    public let frames: Int
    public let totalFrames: Int
    public let remainingSeconds: Double?
    public var fraction: Double { min(1, Double(frames) / Double(max(1, totalFrames))) }
    public var elapsedVideoSeconds: Double { Double(frames) / 240 }
}

public struct ConversionDependencies {
    public let ffmpeg: URL?
    public let ffprobe: URL?
    public let x265: URL?
    public let x265Version: String?
    public let x265Architecture: String?
    public var ready: Bool { ffmpeg != nil && ffprobe != nil && x265 != nil }
}

public enum RuntimeArchitecture {
    public static var label: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
    static var executableDirectories: [String] {
        #if arch(arm64)
        return ["/opt/homebrew/bin", "/usr/local/bin"]
        #else
        return ["/usr/local/bin", "/opt/homebrew/bin"]
        #endif
    }
}

public enum X265Locator {
    public static func locate() -> URL? {
        ExecutableLocator.locate("x265", candidates: RuntimeArchitecture.executableDirectories.map { "\($0)/x265" })
    }
    static func locate(candidates: [String], searchPATH: Bool) -> URL? {
        ExecutableLocator.locate("x265", candidates: candidates, searchPATH: searchPATH)
    }
}

public enum FFmpegLocator {
    public static func locate() -> URL? {
        ExecutableLocator.locate("ffmpeg", candidates: RuntimeArchitecture.executableDirectories.map { "\($0)/ffmpeg" })
    }
    public static func locateProbe() -> URL? {
        ExecutableLocator.locate("ffprobe", candidates: RuntimeArchitecture.executableDirectories.map { "\($0)/ffprobe" })
    }
    static func locate(candidates: [String], searchPATH: Bool) -> URL? {
        ExecutableLocator.locate("ffmpeg", candidates: candidates, searchPATH: searchPATH)
    }
}

enum AerialMediaProbe {
    static func stream(_ source: URL, executable: URL) throws -> [String: Any] {
        let task = Process(), pipe = Pipe()
        task.executableURL = executable
        task.arguments = ["-v", "error", "-select_streams", "v:0", "-show_entries",
                          "stream=codec_name,codec_tag_string,profile,pix_fmt,color_range,color_space,color_transfer,color_primaries,width,height,duration,nb_frames,r_frame_rate,avg_frame_rate",
                          "-of", "json", source.path]
        task.standardOutput = pipe; task.standardError = Pipe()
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stream = (root["streams"] as? [[String: Any]])?.first else {
            throw SwitcherError("ffprobe 无法读取视频轨道。")
        }
        return stream
    }
}

enum AerialInputColor {
    static func conversionFilter(for stream: [String: Any]) throws -> String? {
        let fields = ["color_space", "color_transfer", "color_primaries"]
        let values = fields.map { stream[$0] as? String ?? "unknown" }
        for (field, value) in zip(fields, values) where !["bt709", "smpte170m", "bt470bg", "unknown"].contains(value) {
            throw SwitcherError("源视频色彩标记 \(field)=\(value) 暂不支持安全转换。")
        }
        guard let sourceSD = values.first(where: { $0 == "smpte170m" || $0 == "bt470bg" }) else { return nil }
        // Keep each known source component; only missing tags inherit the known SD source.
        let inputs = values.map { $0 == "unknown" ? sourceSD : $0 }
        return "colorspace=all=bt709:range=tv:format=yuv420p10:" +
            "ispace=\(inputs[0]):itrc=\(inputs[1]):iprimaries=\(inputs[2]):irange=tv"
    }
}

private enum ExecutableLocator {
    static func locate(_ name: String, candidates: [String], searchPATH: Bool = true) -> URL? {
        let fm = FileManager.default
        for path in candidates where fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        guard searchPATH else { return nil }
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = [name]
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasPrefix("/"), fm.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}

public final class ConversionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var processes: [Process] = []
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func cancel() {
        lock.lock(); cancelled = true; let running = processes; lock.unlock()
        for process in running where process.isRunning { process.terminate() }
    }
    func track(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw SwitcherError("转换已取消。") }
        processes.append(process)
    }
    func untrackAll() { lock.lock(); processes.removeAll(); lock.unlock() }
    func requireActive() throws { if isCancelled { throw SwitcherError("转换已取消。") } }
}

public enum AerialResolution {
    public static func output(width: Int, height: Int) -> (Int, Int) {
        guard width > 0, height > 0 else { return (0, 0) }
        let ratio = min(1.0, min(3840.0 / Double(width), 2160.0 / Double(height)))
        // HEVC 4:2:0 requires even dimensions. Preserve orientation and aspect within one pixel.
        let w = max(2, Int((Double(width) * ratio / 2).rounded(.down)) * 2)
        let h = max(2, Int((Double(height) * ratio / 2).rounded(.down)) * 2)
        return (w, h)
    }
}

public struct ConvertedAerialVideo {
    public let movie: URL
    public let details: VideoDetails
    public let report: AerialCompatibilityReport
}

public struct AerialVideoConverter {
    private let helperOverride: URL?
    public init(helperOverride: URL? = nil) { self.helperOverride = helperOverride }
    public static func dependencies() -> ConversionDependencies {
        var x265 = X265Locator.locate()
        var version: String?
        if let candidate = x265 {
            let task = Process(); let pipe = Pipe()
            task.executableURL = candidate; task.arguments = ["--version"]
            task.standardError = pipe; task.standardOutput = pipe
            if (try? task.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                if task.terminationStatus == 0 {
                    version = String(data: data, encoding: .utf8)?.split(separator: "\n").first.map(String.init)
                } else {
                    x265 = nil
                }
            } else {
                x265 = nil
            }
        }
        var architecture: String?
        if let x265 {
            let task = Process(); let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/file")
            task.arguments = ["-L", x265.path]
            task.standardOutput = pipe; task.standardError = Pipe()
            if (try? task.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                let description = String(decoding: data, as: UTF8.self)
                if description.contains("arm64") && description.contains("x86_64") {
                    architecture = "x265: Universal"
                } else if description.contains("arm64") {
                    architecture = "x265: Apple Silicon build"
                } else if description.contains("x86_64") {
                    architecture = "x265: Intel build"
                }
            }
        }
        return .init(ffmpeg: FFmpegLocator.locate(), ffprobe: FFmpegLocator.locateProbe(),
                     x265: x265, x265Version: version, x265Architecture: architecture)
    }

    public static func helperURL() -> URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AerialMediaHelper")
    }

    public func convert(_ source: URL, details: VideoDetails, options: ConversionOptions,
                        scratch: URL, cancellation: ConversionCancellation,
                        progress: @escaping (ConversionProgress) -> Void) throws -> ConvertedAerialVideo {
        let deps = Self.dependencies()
        guard let ffmpeg = deps.ffmpeg, let ffprobe = deps.ffprobe, let x265 = deps.x265 else {
            throw SwitcherError("缺少 ffmpeg、ffprobe 或 x265。请安装依赖后重试；转换没有开始。")
        }
        let sourceStream = try AerialMediaProbe.stream(source, executable: ffprobe)
        // Audio can outlast video by a fraction of a frame; encode from the video timeline.
        let streamDuration = (sourceStream["duration"] as? String).flatMap(Double.init)
        let videoDuration = streamDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? details.duration
        let colorConversion = try AerialInputColor.conversionFilter(for: sourceStream)
        let range = sourceStream["color_range"] as? String ?? "unknown"
        guard range == "tv" || range == "unknown" else {
            throw SwitcherError("源视频使用 full range；当前版本不会错误地将其标记为 limited。")
        }
        let helper = helperOverride ?? Self.helperURL()
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw SwitcherError("App 缺少 AerialMediaHelper；请重新构建应用。")
        }
        guard videoDuration.isFinite, videoDuration > 0, videoDuration <= 240 else {
            throw SwitcherError("当前转换器支持 4 分钟以内的视频；未写入墙纸资源。")
        }
        let (width, height) = AerialResolution.output(width: details.width, height: details.height)
        guard width >= 2, height >= 2 else { throw SwitcherError("视频尺寸无效。") }
        let fm = FileManager.default
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let pingPong = options.pingPong ? try AerialPingPongBuilder().prepare(
            source, stream: sourceStream, details: details, duration: videoDuration,
            scratch: scratch, ffmpeg: ffmpeg, ffprobe: ffprobe, cancellation: cancellation,
            progress: progress) : nil
        let frames = pingPong?.outputFrames ?? Int((videoDuration * 240).rounded())
        guard frames > 0 else { throw SwitcherError("视频太短，无法生成 240 fps 时间轴。") }
        let expectedDuration = pingPong.map { Double($0.outputFrames) / 240 } ?? videoDuration
        let hevc = scratch.appendingPathComponent("video.hevc")
        let csv = scratch.appendingPathComponent("frames.csv")
        let mov = scratch.appendingPathComponent("converted.mov")
        let ffLog = scratch.appendingPathComponent("ffmpeg.log")
        var completed = false
        defer {
            if !completed {
                for path in [hevc, csv, mov, ffLog] where fm.fileExists(atPath: path.path) {
                    try? fm.removeItem(at: path)
                }
            }
        }
        let ffHandle = fm.createFile(atPath: ffLog.path, contents: nil)
        guard ffHandle, let ffError = FileHandle(forWritingAtPath: ffLog.path) else {
            throw SwitcherError("无法创建转换日志。")
        }
        defer { try? ffError.close() }
        let filters = [colorConversion,
            "fps=240:start_time=0:round=near",
            width == details.width && height == details.height ? nil : "scale=\(width):\(height):flags=lanczos",
            "format=yuv420p10le"].compactMap { $0 }.joined(separator: ",")
        let ff = Process(), enc = Process()
        let rawPipe = Pipe(), encError = Pipe()
        ff.executableURL = ffmpeg
        if let pingPong {
            let graph = pingPong.filterPrefix + "," + filters + "[out]"
            ff.arguments = ["-hide_banner", "-loglevel", "error", "-i", source.path,
                            "-f", "concat", "-safe", "0", "-i", pingPong.playlist.path,
                            "-filter_complex", graph, "-map", "[out]", "-an", "-sn", "-dn",
                            "-frames:v", String(frames), "-pix_fmt", "yuv420p10le",
                            "-f", "rawvideo", "pipe:1"]
        } else {
            ff.arguments = ["-hide_banner", "-loglevel", "error", "-i", source.path, "-an", "-sn", "-dn",
                            "-vf", filters, "-frames:v", String(frames),
                            "-pix_fmt", "yuv420p10le", "-f", "rawvideo", "pipe:1"]
        }
        ff.standardOutput = rawPipe; ff.standardError = ffError
        enc.executableURL = x265
        enc.arguments = ["--input", "-", "--input-res", "\(width)x\(height)", "--fps", "240",
                         "--input-depth", "10", "--output-depth", "10", "--profile", "main10",
                         "--frames", String(frames),
                         "--output", hevc.path, "--csv", csv.path, "--csv-log-level", "2",
                         "--preset", "medium", "--crf", String(options.quality.crf),
                         "--temporal-layers", "5", "--bframes", "15", "--b-adapt", "0",
                         "--rc-lookahead", "20", "--no-scenecut", "--keyint", String(frames + 16),
                         "--min-keyint", String(frames + 16), "--repeat-headers", "--range", "limited",
                         "--colorprim", "bt709", "--transfer", "bt709", "--colormatrix", "bt709", "--sar", "1"]
        enc.standardInput = rawPipe; enc.standardError = encError
        try cancellation.requireActive()
        try cancellation.track(ff)
        try cancellation.track(enc)
        defer { cancellation.untrackAll() }
        let started = Date()
        let readDone = DispatchSemaphore(value: 0)
        var encoderLog = ""
        let frameRegex = try NSRegularExpression(pattern: #"(\d+)(?:/\d+)?\s+frames"#)
        do {
            try ff.run()
            try enc.run()
            rawPipe.fileHandleForWriting.closeFile()
            DispatchQueue.global(qos: .utility).async {
                let handle = encError.fileHandleForReading
                var pending = ""
                while let data = try? handle.read(upToCount: 4096), !data.isEmpty {
                    let chunk = String(decoding: data, as: UTF8.self)
                    encoderLog += chunk
                    if encoderLog.utf8.count > 16_384 { encoderLog = String(encoderLog.suffix(8_192)) }
                    pending += chunk
                    let parts = pending.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
                    pending = parts.last ?? ""
                    for line in parts.dropLast() {
                        let nsline = line as NSString
                        if let match = frameRegex.firstMatch(in: line, range: NSRange(location: 0, length: nsline.length)),
                           let count = Int(nsline.substring(with: match.range(at: 1))), count > 0 {
                            let elapsed = Date().timeIntervalSince(started)
                            let remaining = elapsed / Double(count) * Double(max(0, frames - count))
                            progress(.init(stage: "编码动态壁纸", frames: min(count, frames),
                                           totalFrames: frames, remainingSeconds: remaining))
                        }
                    }
                }
                readDone.signal()
            }
            enc.waitUntilExit()
            ff.waitUntilExit()
            readDone.wait()
            try cancellation.requireActive()
            guard ff.terminationStatus == 0 && enc.terminationStatus == 0 else {
                throw SwitcherError("视频编码失败。ffmpeg=\(ff.terminationStatus)，x265=\(enc.terminationStatus)。\(encoderLog.suffix(400))")
            }
            progress(.init(stage: "封装 240 fps MOV", frames: frames, totalFrames: frames, remainingSeconds: nil))
            try runHelper(helper, ["write", hevc.path, csv.path, mov.path], cancellation: cancellation)
            progress(.init(stage: "完整兼容性校验", frames: frames, totalFrames: frames, remainingSeconds: nil))
            let report = try AerialCompatibilityChecker().check(mov, expectedFrames: frames,
                expectedDuration: expectedDuration, expectedWidth: width, expectedHeight: height,
                ffmpeg: ffmpeg, cancellation: cancellation)
            let output = try AVFoundationVideoInspector().inspect(mov)
            completed = true
            return .init(movie: mov, details: output, report: report)
        } catch {
            if ff.isRunning { ff.terminate(); ff.waitUntilExit() }
            if enc.isRunning { enc.terminate(); enc.waitUntilExit() }
            throw error
        }
    }

    private func runHelper(_ url: URL, _ args: [String], cancellation: ConversionCancellation) throws {
        let task = Process(), pipe = Pipe()
        task.executableURL = url; task.arguments = args
        task.standardOutput = pipe; task.standardError = pipe
        try cancellation.track(task)
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        try cancellation.requireActive()
        guard task.terminationStatus == 0 else {
            throw SwitcherError("MOV 封装失败：\(String(decoding: data.suffix(800), as: UTF8.self))")
        }
    }
}

struct AerialPingPongBuilder {
    struct Prepared {
        let playlist: URL
        let filterPrefix: String
        let outputFrames: Int
    }

    func prepare(_ source: URL, stream: [String: Any], details: VideoDetails, duration: Double,
                 scratch: URL, ffmpeg: URL, ffprobe: URL, cancellation: ConversionCancellation,
                 progress: (ConversionProgress) -> Void) throws -> Prepared {
        guard let rate = stream["avg_frame_rate"] as? String,
              let fps = Self.frameRate(rate), fps > 0, fps <= 120,
              let nominal = Self.frameRate(stream["r_frame_rate"] as? String ?? ""),
              abs(fps - nominal) < 0.01,
              let sourceFrames = Int(stream["nb_frames"] as? String ?? ""), sourceFrames >= 3,
              abs(Double(sourceFrames) / fps - duration) < max(0.08, 2 / fps) else {
            throw SwitcherError("正放后倒放需要可确认帧数的固定帧率视频；原视频未修改。")
        }
        guard Double(sourceFrames * 2 - 2) / fps <= 240 else {
            throw SwitcherError("正放后倒放的成片超过 4 分钟；请选择较短的视频。")
        }
        let pixelCount = max(1, details.width * details.height)
        let chunkFrames = max(2, min(Int((fps * 2).rounded()), 150_000_000 / pixelCount))
        let chunkCount = (sourceFrames + chunkFrames - 1) / chunkFrames
        var chunkNames: [String] = []
        let estimatedFrames = max(1, Int((Double(sourceFrames * 2 - 2) * 240 / fps).rounded()))
        for index in 0..<chunkCount {
            try cancellation.requireActive()
            let start = index * chunkFrames
            let count = min(chunkFrames, sourceFrames - start)
            let keep = count - (index == 0 ? 1 : 0) - (index == chunkCount - 1 ? 1 : 0)
            guard keep > 0 else { throw SwitcherError("视频太短，无法生成连续的往返画面。") }
            let name = String(format: "reverse-%05d.mkv", index)
            let chunk = scratch.appendingPathComponent(name)
            var filters = ["fps=fps=\(rate):start_time=0:round=near", "trim=end_frame=\(count)"]
            if index == 0 { filters.append("trim=start_frame=1") }
            filters.append("reverse")
            if index == chunkCount - 1 { filters.append("trim=start_frame=1") }
            filters += ["setpts=N/(\(rate)*TB)", "format=yuv420p10le"]
            _ = try execute(ffmpeg, ["-hide_banner", "-loglevel", "error", "-ss", String(Double(start) / fps),
                                     "-i", source.path, "-an", "-sn", "-dn", "-vf", filters.joined(separator: ","),
                                     "-frames:v", String(keep), "-c:v", "ffv1", "-level", "3",
                                     "-pix_fmt", "yuv420p10le", "-y", chunk.path],
                            cancellation: cancellation, stage: "准备倒放片段")
            let actual = try packetCount(chunk, ffprobe: ffprobe, cancellation: cancellation)
            guard actual == keep else {
                throw SwitcherError("倒放片段帧数不符：\(actual) / \(keep)。未安装壁纸。")
            }
            chunkNames.append(name)
            progress(.init(stage: "准备倒放片段 \(index + 1)/\(chunkCount)", frames: 0,
                           totalFrames: estimatedFrames, remainingSeconds: nil))
        }
        let playlist = scratch.appendingPathComponent("reverse.ffconcat")
        let contents = "ffconcat version 1.0\n" + chunkNames.reversed().map { "file '\($0)'\n" }.joined()
        try contents.write(to: playlist, atomically: true, encoding: .utf8)
        let prefix = "[0:v]fps=fps=\(rate):start_time=0:round=near,setpts=N/(\(rate)*TB),format=yuv420p10le[f];" +
            "[1:v]setpts=N/(\(rate)*TB),format=yuv420p10le[r];[f][r]concat=n=2:v=1:a=0"
        let preflight = prefix + ",fps=240:start_time=0:round=near[out]"
        let output = try execute(ffmpeg, ["-hide_banner", "-loglevel", "error", "-i", source.path,
                                          "-f", "concat", "-safe", "0", "-i", playlist.path,
                                          "-filter_complex", preflight, "-map", "[out]", "-an", "-f", "null", "-",
                                          "-progress", "pipe:1"],
                                 cancellation: cancellation, stage: "检查往返时间轴")
        let frames = output.split(separator: "\n").filter { $0.hasPrefix("frame=") }
            .last.flatMap { Int($0.dropFirst("frame=".count)) } ?? 0
        guard frames > 0, frames <= 240 * 240 else {
            throw SwitcherError("无法确认往返时间轴的帧数；未安装壁纸。")
        }
        return .init(playlist: playlist, filterPrefix: prefix, outputFrames: frames)
    }

    private static func frameRate(_ value: String) -> Double? {
        let parts = value.split(separator: "/")
        guard let numerator = Double(parts.first ?? ""),
              let denominator = parts.count == 2 ? Double(parts[1]) : 1.0,
              denominator > 0 else { return nil }
        return numerator / denominator
    }

    private func packetCount(_ movie: URL, ffprobe: URL, cancellation: ConversionCancellation) throws -> Int {
        let result = try execute(ffprobe, ["-v", "error", "-count_packets", "-select_streams", "v:0",
                                           "-show_entries", "stream=nb_read_packets", "-of",
                                           "default=nokey=1:noprint_wrappers=1", movie.path],
                                 cancellation: cancellation, stage: "校验倒放片段")
        return Int(result.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func execute(_ executable: URL, _ arguments: [String], cancellation: ConversionCancellation,
                         stage: String) throws -> String {
        let task = Process(), stdout = Pipe(), stderr = Pipe()
        task.executableURL = executable
        task.arguments = arguments
        task.standardOutput = stdout
        task.standardError = stderr
        try cancellation.track(task)
        try task.run()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errors = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()
        try cancellation.requireActive()
        guard task.terminationStatus == 0 else {
            throw SwitcherError("\(stage)失败：\(errors.suffix(400))")
        }
        return output
    }
}
