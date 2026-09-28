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
    public init(quality: QualityPreset = .standard) { self.quality = quality }
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
    public var ready: Bool { ffmpeg != nil && ffprobe != nil && x265 != nil }
}

public enum X265Locator {
    public static func locate() -> URL? {
        ExecutableLocator.locate("x265", candidates: ["/usr/local/bin/x265", "/opt/homebrew/bin/x265"])
    }
    static func locate(candidates: [String], searchPATH: Bool) -> URL? {
        ExecutableLocator.locate("x265", candidates: candidates, searchPATH: searchPATH)
    }
}

public enum FFmpegLocator {
    public static func locate() -> URL? {
        ExecutableLocator.locate("ffmpeg", candidates: ["/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg"])
    }
    public static func locateProbe() -> URL? {
        ExecutableLocator.locate("ffprobe", candidates: ["/usr/local/bin/ffprobe", "/opt/homebrew/bin/ffprobe"])
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
                          "stream=codec_name,codec_tag_string,profile,pix_fmt,color_range,color_space,color_transfer,color_primaries,width,height,nb_frames,r_frame_rate",
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
        let x265 = X265Locator.locate()
        var version: String?
        if let x265 {
            let task = Process(); let pipe = Pipe()
            task.executableURL = x265; task.arguments = ["--version"]
            task.standardError = pipe; task.standardOutput = pipe
            if (try? task.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                version = String(data: data, encoding: .utf8)?.split(separator: "\n").first.map(String.init)
            }
        }
        return .init(ffmpeg: FFmpegLocator.locate(), ffprobe: FFmpegLocator.locateProbe(),
                     x265: x265, x265Version: version)
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
        for field in ["color_space", "color_transfer", "color_primaries"] {
            let value = sourceStream[field] as? String ?? "unknown"
            guard value == "bt709" || value == "unknown" else {
                throw SwitcherError("源视频为 \(value)，当前已验证的 BT.709 转换链不能安全处理该色彩格式。")
            }
        }
        let range = sourceStream["color_range"] as? String ?? "unknown"
        guard range == "tv" || range == "unknown" else {
            throw SwitcherError("源视频使用 full range；当前版本不会错误地将其标记为 limited。")
        }
        let helper = helperOverride ?? Self.helperURL()
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw SwitcherError("App 缺少 AerialMediaHelper；请重新构建应用。")
        }
        guard details.duration.isFinite, details.duration > 0, details.duration <= 240 else {
            throw SwitcherError("当前转换器支持 4 分钟以内的视频；未写入墙纸资源。")
        }
        let (width, height) = AerialResolution.output(width: details.width, height: details.height)
        guard width >= 2, height >= 2 else { throw SwitcherError("视频尺寸无效。") }
        let frames = Int((details.duration * 240).rounded())
        guard frames > 0 else { throw SwitcherError("视频太短，无法生成 240 fps 时间轴。") }
        let fm = FileManager.default
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
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
        let filters = ["fps=240:start_time=0:round=near",
            width == details.width && height == details.height ? nil : "scale=\(width):\(height):flags=lanczos",
            "format=yuv420p10le"].compactMap { $0 }.joined(separator: ",")
        let ff = Process(), enc = Process()
        let rawPipe = Pipe(), encError = Pipe()
        ff.executableURL = ffmpeg
        ff.arguments = ["-hide_banner", "-loglevel", "error", "-i", source.path, "-an", "-sn", "-dn",
                        "-vf", filters, "-frames:v", String(frames),
                        "-pix_fmt", "yuv420p10le", "-f", "rawvideo", "pipe:1"]
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
                expectedDuration: details.duration, expectedWidth: width, expectedHeight: height,
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
