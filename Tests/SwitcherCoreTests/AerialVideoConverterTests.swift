import Foundation
import XCTest
@testable import SwitcherCore

final class AerialVideoConverterTests: XCTestCase {
    func testResolutionPreservesSmallerInputsAndPortrait() {
        let a = AerialResolution.output(width: 1920, height: 1080)
        XCTAssertEqual(a.0, 1920); XCTAssertEqual(a.1, 1080)
        let b = AerialResolution.output(width: 3840, height: 2160)
        XCTAssertEqual(b.0, 3840); XCTAssertEqual(b.1, 2160)
        let portrait = AerialResolution.output(width: 1080, height: 1920)
        XCTAssertEqual(portrait.0, 1080); XCTAssertEqual(portrait.1, 1920)
        let large = AerialResolution.output(width: 7680, height: 4320)
        XCTAssertEqual(large.0, 3840); XCTAssertEqual(large.1, 2160)
        let largePortrait = AerialResolution.output(width: 2160, height: 3840)
        XCTAssertEqual(largePortrait.0, 1214); XCTAssertEqual(largePortrait.1, 2160)
    }

    func testExplicitMissingExecutablesCannotStartConversion() {
        XCTAssertNil(X265Locator.locate(candidates: ["/missing/x265"], searchPATH: false))
        XCTAssertNil(FFmpegLocator.locate(candidates: ["/missing/ffmpeg"], searchPATH: false))
    }

    func testFFmpegTimestampResamplingAcrossInputRates() throws {
        guard let ffmpeg = FFmpegLocator.locate() else { throw XCTSkip("ffmpeg 未安装") }
        for rate in ["24000/1001", "24", "25", "30000/1001", "30", "50", "60000/1001", "60"] {
            let task = Process(), output = Pipe()
            task.executableURL = ffmpeg
            task.arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                              "testsrc2=size=64x64:rate=\(rate)", "-t", "1",
                              "-vf", "fps=240:start_time=0:round=near", "-f", "null", "-",
                              "-progress", "pipe:1"]
            task.standardOutput = output; task.standardError = Pipe()
            try task.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            task.waitUntilExit()
            XCTAssertEqual(task.terminationStatus, 0, rate)
            let frame = text.split(separator: "\n").filter { $0.hasPrefix("frame=") }.last
            XCTAssertEqual(frame, "frame=240", "rate=\(rate), output=\(text.suffix(200))")
        }
    }

    func testCancelTokenStopsBeforeStartingAProcess() {
        let token = ConversionCancellation()
        token.cancel()
        XCTAssertTrue(token.isCancelled)
        XCTAssertThrowsError(try token.requireActive())
        XCTAssertThrowsError(try token.track(Process()))
    }

    func testInvalidMovieCannotModifyManifest() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("dws-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = AerialPaths(manifest: base.appendingPathComponent("manifest/entries.json"),
                                videos: base.appendingPathComponent("videos"),
                                support: base.appendingPathComponent("support"))
        try FileManager.default.createDirectory(at: paths.manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(#"{"assets":[],"categories":[]}"#.utf8)
        try data.write(to: paths.manifest)
        let fake = base.appendingPathComponent("fake.mov")
        try Data("not video".utf8).write(to: fake)
        let manager = CustomAerialManager(paths: paths)
        XCTAssertThrowsError(try manager.importConvertedVideo(fake, sourceFilename: "fake.mp4", displayName: "fake"))
        XCTAssertEqual(try Data(contentsOf: paths.manifest), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("support/CustomAerials/metadata.json").path))
    }

    func testKnownVerifiedMoviePassesStructureAndReaderCheck() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let movie = ProcessInfo.processInfo.environment["DWS_TEST_MOV"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("diagnostics/sample_video-aerial-1080p.mov")
        guard FileManager.default.fileExists(atPath: movie.path) else { throw XCTSkip("本机 POC 参考 MOV 不在源码中") }
        let report = try AerialCompatibilityChecker().check(movie, expectedFrames: 2400,
            expectedDuration: 10, expectedWidth: 1920, expectedHeight: 1080)
        XCTAssertEqual(report.sampleCount, 2400)
        XCTAssertEqual(report.matchedTemporalSamples, 2400)
    }

    func testConverterEndToEndWithoutInstallingAerialAsset() throws {
        guard let ffmpeg = FFmpegLocator.locate(), X265Locator.locate() != nil else {
            throw XCTSkip("本机缺少编码依赖")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = root.appendingPathComponent(".build/release/TemporalSampleWriterPOC")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw XCTSkip("请先构建 TemporalSampleWriterPOC helper")
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("dws-integrated-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let source = scratch.appendingPathComponent("source.mp4")
        let make = Process(), makeError = Pipe()
        make.executableURL = ffmpeg
        make.arguments = ["-hide_banner", "-v", "error", "-f", "lavfi", "-i",
                          "testsrc2=size=320x180:rate=30", "-t", "1", "-c:v", "mpeg4",
                          "-color_range", "tv", "-colorspace", "bt709", "-color_trc", "bt709",
                          "-color_primaries", "bt709", source.path]
        make.standardOutput = Pipe(); make.standardError = makeError
        try make.run()
        let errorText = String(decoding: makeError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        make.waitUntilExit()
        XCTAssertEqual(make.terminationStatus, 0, errorText)
        let details = try AVFoundationVideoInspector().inspect(source)
        var progressEvents: [ConversionProgress] = []
        let result = try AerialVideoConverter(helperOverride: helper).convert(source, details: details,
            options: .init(), scratch: scratch.appendingPathComponent("work"),
            cancellation: ConversionCancellation(), progress: { progressEvents.append($0) })
        XCTAssertEqual(result.report.sampleCount, 240)
        XCTAssertEqual(result.report.matchedTemporalSamples, 240)
        XCTAssertEqual(result.details.width, 320)
        XCTAssertEqual(result.details.height, 180)
        XCTAssertTrue(progressEvents.contains { $0.stage == "编码动态壁纸" && $0.frames > 0 },
                      "x265 必须报告实际已编码帧数")
        let cancelled = ConversionCancellation()
        cancelled.cancel()
        let cancelledScratch = scratch.appendingPathComponent("cancelled")
        XCTAssertThrowsError(try AerialVideoConverter(helperOverride: helper).convert(source, details: details,
            options: .init(), scratch: cancelledScratch, cancellation: cancelled, progress: { _ in }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cancelledScratch.path), [])
    }
}
