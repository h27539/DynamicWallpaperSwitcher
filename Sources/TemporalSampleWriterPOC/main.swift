import Foundation
import AVFoundation
import CoreMedia

struct Unit {
    let bytes: [UInt8]
    var type: Int { Int((bytes[0] >> 1) & 0x3f) }
    var temporalID: Int { Int(bytes[1] & 7) - 1 }
}

struct ProfileTierLevel {
    let profileSpace: Int
    let tier: Int
    let profileIndex: Int
    let compatibility: Data
    let constraints: Data
    let levelIndex: Int
}

struct BitReader {
    let bytes: [UInt8]
    var position = 0
    mutating func take(_ bits: Int) -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<bits {
            value = (value << 1) | UInt64((bytes[position / 8] >> (7 - position % 8)) & 1)
            position += 1
        }
        return value
    }
}

func profileTierLevel(_ vps: Unit) -> ProfileTierLevel {
    var rbsp: [UInt8] = []
    for byte in vps.bytes.dropFirst(2) {
        if rbsp.count >= 2 && rbsp[rbsp.count - 2] == 0 && rbsp[rbsp.count - 1] == 0 && byte == 3 {
            continue
        }
        rbsp.append(byte)
    }
    var bits = BitReader(bytes: rbsp)
    _ = bits.take(32) // VPS header before profile_tier_level
    let space = Int(bits.take(2)), tier = Int(bits.take(1)), profile = Int(bits.take(5))
    let compatibility = bits.take(32), constraints = bits.take(48), level = Int(bits.take(8))
    return ProfileTierLevel(profileSpace: space, tier: tier, profileIndex: profile,
        compatibility: Data((0..<4).map { UInt8((compatibility >> (24 - 8 * $0)) & 255) }),
        constraints: Data((0..<6).map { UInt8((constraints >> (40 - 8 * $0)) & 255) }),
        levelIndex: level)
}

func units(_ bytes: [UInt8]) -> [Unit] {
    var starts: [(Int, Int)] = []
    var i = 0
    while i + 4 < bytes.count {
        if bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 1 {
            starts.append((i, 3)); i += 3
        } else if bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 1 {
            starts.append((i, 4)); i += 4
        } else { i += 1 }
    }
    return starts.enumerated().compactMap { index, pair in
        let end = index + 1 < starts.count ? starts[index + 1].0 : bytes.count
        let payload = Array(bytes[(pair.0 + pair.1)..<end])
        return payload.count >= 3 ? Unit(bytes: payload) : nil
    }
}

func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw NSError(domain: "TemporalSampleWriterPOC.\(operation)", code: Int(status)) }
}

func formatDescription(_ parameters: [Unit]) throws -> CMVideoFormatDescription {
    let selected = [32, 33, 34].compactMap { type in parameters.first(where: { $0.type == type }) }
    guard selected.count == 3 else { throw NSError(domain: "TemporalSampleWriterPOC.missingParameterSet", code: -1) }
    let storage = selected.map { unit -> UnsafeMutablePointer<UInt8> in
        let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: unit.bytes.count)
        pointer.initialize(from: unit.bytes, count: unit.bytes.count)
        return pointer
    }
    defer { storage.forEach { $0.deallocate() } }
    var pointers: [UnsafePointer<UInt8>] = storage.map { UnsafePointer($0) }
    var sizes = selected.map { $0.bytes.count }
    var result: CMFormatDescription?
    try check(CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault,
        parameterSetCount: pointers.count, parameterSetPointers: &pointers,
        parameterSetSizes: &sizes, nalUnitHeaderLength: 4, extensions: nil,
        formatDescriptionOut: &result), "formatDescription")
    guard let result else { throw NSError(domain: "TemporalSampleWriterPOC.nilFormat", code: -1) }
    return result
}

func sample(_ unit: Unit, poc: Int, decodeIndex: Int,
            format: CMVideoFormatDescription, profile: ProfileTierLevel,
            attachTemporal: Bool, attachTSAS: Bool) throws -> CMSampleBuffer {
    let count = unit.bytes.count
    let payload = [UInt8((count >> 24) & 255), UInt8((count >> 16) & 255),
                   UInt8((count >> 8) & 255), UInt8(count & 255)] + unit.bytes
    var block: CMBlockBuffer?
    try check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
        blockLength: payload.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
        offsetToData: 0, dataLength: payload.count, flags: 0, blockBufferOut: &block), "block")
    guard let block else { throw NSError(domain: "TemporalSampleWriterPOC.nilBlock", code: -1) }
    try payload.withUnsafeBytes { raw in
        try check(CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
            offsetIntoDestination: 0, dataLength: payload.count), "copyBytes")
    }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 240),
        presentationTimeStamp: CMTime(value: Int64(poc + 4), timescale: 240),
        decodeTimeStamp: CMTime(value: Int64(decodeIndex), timescale: 240))
    var size = payload.count
    var result: CMSampleBuffer?
    try check(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
        formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
        sampleBufferOut: &result), "sample")
    guard let result else { throw NSError(domain: "TemporalSampleWriterPOC.nilSample", code: -1) }
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true) as? [NSMutableDictionary],
          let attachment = attachments.first else {
        throw NSError(domain: "TemporalSampleWriterPOC.nilAttachments", code: -1)
    }
    if attachTemporal {
        attachment[kCMSampleAttachmentKey_HEVCTemporalLevelInfo as String] = [
            kCMHEVCTemporalLevelInfoKey_TemporalLevel as String: unit.temporalID,
            kCMHEVCTemporalLevelInfoKey_ProfileSpace as String: profile.profileSpace,
            kCMHEVCTemporalLevelInfoKey_TierFlag as String: profile.tier,
            kCMHEVCTemporalLevelInfoKey_ProfileIndex as String: profile.profileIndex,
            kCMHEVCTemporalLevelInfoKey_ProfileCompatibilityFlags as String: profile.compatibility,
            kCMHEVCTemporalLevelInfoKey_ConstraintIndicatorFlags as String: profile.constraints,
            kCMHEVCTemporalLevelInfoKey_LevelIndex as String: profile.levelIndex
        ] as NSDictionary
        if attachTSAS && unit.temporalID > 0 {
            attachment[kCMSampleAttachmentKey_HEVCTemporalSubLayerAccess as String] = kCFBooleanTrue
        }
    }
    if decodeIndex > 0 { attachment[kCMSampleAttachmentKey_NotSync as String] = kCFBooleanTrue }
    return result
}

func metadata(_ csv: URL) throws -> [(poc: Int, level: Int)] {
    let lines = try String(contentsOf: csv, encoding: .utf8).split(separator: "\n")
    return lines.dropFirst().compactMap { line in
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count > 7, let poc = Int(fields[3].trimmingCharacters(in: .whitespaces)),
              let level = Int(fields[7].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (poc, level)
    }
}

final class HEVCUnitStream {
    private let handle: FileHandle
    private var pending: [UInt8] = []
    private var eof = false
    init(_ url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
    deinit { try? handle.close() }

    private func starts() -> [(Int, Int)] {
        var result: [(Int, Int)] = []
        var i = 0
        while i + 3 < pending.count {
            if pending[i] == 0 && pending[i + 1] == 0 && pending[i + 2] == 0 && pending[i + 3] == 1 {
                result.append((i, 4)); i += 4
            } else if pending[i] == 0 && pending[i + 1] == 0 && pending[i + 2] == 1 {
                result.append((i, 3)); i += 3
            } else { i += 1 }
        }
        return result
    }

    func next() throws -> Unit? {
        while true {
            let markers = starts()
            if markers.count >= 2 {
                let payload = Array(pending[(markers[0].0 + markers[0].1)..<markers[1].0])
                pending.removeFirst(markers[1].0)
                if payload.count >= 3 { return Unit(bytes: payload) }
            } else if eof {
                guard let first = markers.first else { return nil }
                let payload = Array(pending[(first.0 + first.1)..<pending.count])
                pending.removeAll()
                return payload.count >= 3 ? Unit(bytes: payload) : nil
            } else {
                let bytes = try handle.read(upToCount: 65536) ?? Data()
                if bytes.isEmpty { eof = true } else { pending.append(contentsOf: bytes) }
            }
        }
    }
}

func run(raw: URL, csv: URL, destination: URL, attachTemporal: Bool, attachTSAS: Bool) throws {
    let stream = try HEVCUnitStream(raw)
    var parameters: [Unit] = []
    var firstFrame: Unit?
    while let unit = try stream.next() {
        if unit.type <= 31 { firstFrame = unit; break }
        parameters.append(unit)
    }
    let map = try metadata(csv)
    guard firstFrame != nil, !map.isEmpty else {
        throw NSError(domain: "TemporalSampleWriterPOC.frameCount", code: 0)
    }
    guard Set(map.map(\.poc)) == Set(0..<map.count) else {
        throw NSError(domain: "TemporalSampleWriterPOC.invalidPOC", code: -1)
    }
    let format = try formatDescription(parameters)
    guard let vps = parameters.first(where: { $0.type == 32 }) else {
        throw NSError(domain: "TemporalSampleWriterPOC.missingVPS", code: -1)
    }
    let profile = profileTierLevel(vps)
    let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
    input.expectsMediaDataInRealTime = false
    guard writer.canAdd(input) else { throw NSError(domain: "TemporalSampleWriterPOC.cannotAdd", code: -1) }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? NSError(domain: "TemporalSampleWriterPOC.start", code: -1) }
    writer.startSession(atSourceTime: .zero)
    var index = 0
    var current = firstFrame
    var levels = Set<Int>()
    while let unit = current {
        if unit.type > 31 { current = try stream.next(); continue }
        guard index < map.count, unit.temporalID == map[index].level else {
            throw NSError(domain: "TemporalSampleWriterPOC.temporalMismatch", code: index)
        }
        levels.insert(unit.temporalID)
        let buffer = try sample(unit, poc: map[index].poc, decodeIndex: index, format: format, profile: profile,
                                attachTemporal: attachTemporal, attachTSAS: attachTSAS)
        if index < 2 {
            print("append index=\(index) poc=\(map[index].poc) level=\(unit.temporalID) attachments=\(String(describing: CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)))")
        }
        var attempts = 0
        while !input.isReadyForMoreMediaData && writer.status == .writing && attempts < 1000 {
            Thread.sleep(forTimeInterval: 0.005); attempts += 1
        }
        guard input.isReadyForMoreMediaData, input.append(buffer) else {
            print("append failed index=\(index) writerStatus=\(writer.status.rawValue) ready=\(input.isReadyForMoreMediaData)")
            throw writer.error ?? NSError(domain: "TemporalSampleWriterPOC.append", code: index)
        }
        index += 1
        current = try stream.next()
    }
    guard index == map.count, levels == [0, 1, 2, 3, 4] else {
        writer.cancelWriting()
        throw NSError(domain: "TemporalSampleWriterPOC.incompleteFrames", code: index)
    }
    input.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    semaphore.wait()
    guard writer.status == .completed else {
        throw writer.error ?? NSError(domain: "TemporalSampleWriterPOC.finish", code: -1)
    }
    print("wrote=\(destination.path) samples=\(index) levels=\(levels.sorted())")
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let formal = arguments.first == "write"
    let paths = formal ? Array(arguments.dropFirst()) : arguments
    guard paths.count == 3 || (!formal && paths.count == 4) else {
        fputs("Usage: AerialMediaHelper write <raw.hevc> <x265-frames.csv> <output.mov>\n", stderr)
        exit(2)
    }
    try run(raw: URL(fileURLWithPath: paths[0]),
        csv: URL(fileURLWithPath: paths[1]),
        destination: URL(fileURLWithPath: paths[2]),
        attachTemporal: paths.count == 3 || paths[3] == "--no-tsas",
        attachTSAS: paths.count == 3)
} catch {
    fputs("Writer POC failed: \(error)\n", stderr)
    exit(1)
}
