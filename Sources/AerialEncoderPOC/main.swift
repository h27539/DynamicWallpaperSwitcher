import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox

struct Row {
    let pts: CMTime
    let duration: CMTime
    let sync: Bool
    let level: Int?
    let tsas: Bool
    let nalTemporalID: Int?
}

final class Capture {
    private let lock = NSLock()
    private(set) var errors: [String] = []
    private(set) var rows: [Row] = []
    func add(_ row: Row) { lock.lock(); rows.append(row); lock.unlock() }
    func fail(_ message: String) { lock.lock(); errors.append(message); lock.unlock() }
}

func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw NSError(domain: "AerialEncoderPOC.\(operation)", code: Int(status)) }
}

func firstNALTemporalID(_ sample: CMSampleBuffer) -> Int? {
    guard let data = CMSampleBufferGetDataBuffer(sample) else { return nil }
    var bytes = [UInt8](repeating: 0, count: 6)
    guard CMBlockBufferGetDataLength(data) >= 6,
          CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: 6, destination: &bytes) == noErr else { return nil }
    let nalLength = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
    guard nalLength >= 2 else { return nil }
    return Int(bytes[5] & 7) - 1
}

func attachmentRow(_ sample: CMSampleBuffer) -> Row {
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
    let item = attachments?.first ?? [:]
    let levelInfo = item[kCMSampleAttachmentKey_HEVCTemporalLevelInfo as String] as? [String: Any]
    let level = levelInfo?[kCMHEVCTemporalLevelInfoKey_TemporalLevel as String] as? Int
    let tsas = item[kCMSampleAttachmentKey_HEVCTemporalSubLayerAccess as String] != nil
    let notSync = item[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false
    return Row(pts: CMSampleBufferGetPresentationTimeStamp(sample),
               duration: CMSampleBufferGetDuration(sample), sync: !notSync,
               level: level, tsas: tsas, nalTemporalID: firstNALTemporalID(sample))
}

func createSession(width: Int32, height: Int32, profile: CFString,
                   requireBaseRate: Bool = true, encoderID: String? = nil) throws -> VTCompressionSession {
    var session: VTCompressionSession?
    let encoderSpecification: CFDictionary? = encoderID.map {
        [kVTVideoEncoderSpecification_EncoderID as String: $0] as CFDictionary
    }
    try check(VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
                                         width: width, height: height,
                                         codecType: kCMVideoCodecType_HEVC,
                                         encoderSpecification: encoderSpecification,
                                         imageBufferAttributes: nil,
                                         compressedDataAllocator: nil,
                                         outputCallback: nil,
                                         refcon: nil,
                                         compressionSessionOut: &session), "create")
    guard let session else { throw NSError(domain: "AerialEncoderPOC.noSession", code: -1) }
    do {
        try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile), "profile")
        try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 240 as CFNumber), "expectedFrameRate")
        let baseRateStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_BaseLayerFrameRate, value: 15 as CFNumber)
        if baseRateStatus != noErr {
            print("BaseLayerFrameRate rejected: \(baseRateStatus); trying BaseLayerFrameRateFraction=0.0625")
            let fractionStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_BaseLayerFrameRateFraction,
                                                      value: 0.0625 as CFNumber)
            if fractionStatus != noErr {
                if requireBaseRate { try check(fractionStatus, "baseLayerFrameRateFraction") }
                print("BaseLayerFrameRateFraction also rejected: \(fractionStatus); encoding short control without forced hierarchy")
            }
        }
        try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 1200 as CFNumber), "keyFrameInterval")
        try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 5 as CFNumber), "keyFrameDuration")
        try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowTemporalCompression, value: kCFBooleanTrue), "temporalCompression")
        try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanTrue), "frameReordering")
        try check(VTCompressionSessionPrepareToEncodeFrames(session), "prepare")
    } catch {
        VTCompressionSessionInvalidate(session)
        throw error
    }
    return session
}

func probe(source: URL, seconds: Int, csv: URL, encoderID: String? = nil) throws {
    let asset = AVURLAsset(url: source)
    guard let track = asset.tracks(withMediaType: .video).first else {
        throw NSError(domain: "AerialEncoderPOC.noVideoTrack", code: -1)
    }
    let size = track.naturalSize
    let width = Int32(size.width), height = Int32(size.height)
    let inputFPS = Double(track.nominalFrameRate)
    guard inputFPS > 0, 240.truncatingRemainder(dividingBy: inputFPS) == 0 else {
        throw NSError(domain: "AerialEncoderPOC.unsupportedInputFPS", code: -1)
    }
    let repeats = Int(240 / inputFPS)
    print("input=\(source.path) size=\(width)x\(height) fps=\(inputFPS) repeats=\(repeats)")
    var session: VTCompressionSession?
    var selectedProfile = "Main10"
    var pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    do {
        session = try createSession(width: width, height: height,
                                    profile: kVTProfileLevel_HEVC_Main10_AutoLevel, requireBaseRate: false, encoderID: encoderID)
    } catch {
        print("Main10 rejected: \(error); trying HEVC Main")
        selectedProfile = "Main"
        pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        session = try createSession(width: width, height: height,
                                    profile: kVTProfileLevel_HEVC_Main_AutoLevel, requireBaseRate: false, encoderID: encoderID)
    }
    guard let session else { fatalError("Missing session") }
    defer { VTCompressionSessionInvalidate(session) }
    print("selectedProfile=\(selectedProfile) pixelFormat=\(pixelFormat)")

    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track,
                                          outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? NSError(domain: "AerialEncoderPOC.readerStart", code: -1) }

    let capture = Capture()
    let target = seconds * 240
    var encoded = 0
    while encoded < target, let input = output.copyNextSampleBuffer() {
        guard let image = CMSampleBufferGetImageBuffer(input) else { continue }
        for _ in 0..<repeats where encoded < target {
            let pts = CMTime(value: Int64(encoded), timescale: 240)
            let duration = CMTime(value: 1, timescale: 240)
            let status = VTCompressionSessionEncodeFrame(session,
                imageBuffer: image, presentationTimeStamp: pts, duration: duration,
                frameProperties: nil, infoFlagsOut: nil, outputHandler: { status, _, compressed in
                    if status != noErr { capture.fail("callback status \(status)"); return }
                    guard let compressed else { capture.fail("nil compressed sample"); return }
                    capture.add(attachmentRow(compressed))
                })
            try check(status, "encodeFrame\(encoded)")
            encoded += 1
        }
    }
    try check(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid), "completeFrames")
    print("submitted=\(encoded) callbacks=\(capture.rows.count) errors=\(capture.errors)")
    let rows = capture.rows.sorted { CMTimeCompare($0.pts, $1.pts) < 0 }
    let lines = ["sampleIndex,pts,duration,isSync,temporalLevel,tsas,NAL_temporal_id"] + rows.enumerated().map { i, row in
        "\(i+1),\(row.pts.value)/\(row.pts.timescale),\(row.duration.value)/\(row.duration.timescale),\(row.sync ? 1 : 0),\(row.level.map(String.init) ?? ""),\(row.tsas ? 1 : 0),\(row.nalTemporalID.map(String.init) ?? "")"
    }
    try lines.joined(separator: "\n").write(to: csv, atomically: true, encoding: .utf8)
    let levels = rows.compactMap(\.level)
    print("temporalAttachmentCount=\(levels.count) temporalLevels=\(Set(levels).sorted())")
    print("nalTemporalIDs=\(Set(rows.compactMap(\.nalTemporalID)).sorted())")
    print("attachmentNALMismatch=\(rows.filter { $0.level != nil && $0.nalTemporalID != $0.level }.count)")
    print("CSV=\(csv.path)")
}

do {
    if (CommandLine.arguments.count == 5 || CommandLine.arguments.count == 6), CommandLine.arguments[1] == "probe",
       let seconds = Int(CommandLine.arguments[3]), seconds > 0 {
        try probe(source: URL(fileURLWithPath: CommandLine.arguments[2]),
                  seconds: seconds, csv: URL(fileURLWithPath: CommandLine.arguments[4]),
                  encoderID: CommandLine.arguments.count == 6 ? CommandLine.arguments[5] : nil)
    } else if (CommandLine.arguments.count == 4 || CommandLine.arguments.count == 5), CommandLine.arguments[1] == "capabilities",
              let width = Int32(CommandLine.arguments[2]), let height = Int32(CommandLine.arguments[3]) {
        for (name, profile) in [("Main10", kVTProfileLevel_HEVC_Main10_AutoLevel),
                                ("Main", kVTProfileLevel_HEVC_Main_AutoLevel)] {
            do {
                let session = try createSession(width: width, height: height, profile: profile,
                    encoderID: CommandLine.arguments.count == 5 ? CommandLine.arguments[4] : nil)
                print("\(width)x\(height) \(name): hierarchy properties accepted")
                VTCompressionSessionInvalidate(session)
            } catch {
                print("\(width)x\(height) \(name): \(error)")
            }
        }
    } else {
        fputs("Usage: AerialEncoderPOC probe <input> <seconds> <csv-output> [encoderID] | capabilities <width> <height> [encoderID]\n", stderr)
        exit(2)
    }
} catch {
    fputs("POC stopped: \(error)\n", stderr)
    exit(1)
}
