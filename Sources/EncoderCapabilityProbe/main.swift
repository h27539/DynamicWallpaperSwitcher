import Foundation
import VideoToolbox

func normalized(_ value: Any) -> Any {
    if let dictionary = value as? [AnyHashable: Any] {
        var result: [String: Any] = [:]
        for (key, item) in dictionary { result[String(describing: key)] = normalized(item) }
        return result
    }
    if let array = value as? [Any] { return array.map(normalized) }
    if value is String || value is NSNumber || value is NSNull { return value }
    return String(describing: value)
}

func writeJSON(_ value: Any, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: normalized(value), options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
    try data.write(to: url, options: .atomic)
    _ = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
}

func enumerate() throws -> [[String: Any]] {
    var list: CFArray?
    let status = VTCopyVideoEncoderList(nil, &list)
    guard status == noErr, let list else { throw NSError(domain: "VTCopyVideoEncoderList", code: Int(status)) }
    return (list as NSArray).compactMap { $0 as? [String: Any] }
}

func codecName(_ value: Any?) -> String {
    guard let number = value as? NSNumber else { return "unknown" }
    let raw = number.uint32Value
    return String(bytes: (0..<4).map { UInt8((raw >> (24 - 8 * $0)) & 0xff) }, encoding: .ascii) ?? "unknown"
}

func field(_ entry: [String: Any], _ key: CFString) -> Any { entry[key as String] ?? NSNull() }

func summary(_ entries: [[String: Any]]) -> [[String: Any]] {
    entries.map { entry in
        ["EncoderID": field(entry, kVTVideoEncoderList_EncoderID),
         "EncoderName": field(entry, kVTVideoEncoderList_EncoderName),
         "DisplayName": field(entry, kVTVideoEncoderList_DisplayName),
         "CodecType": field(entry, kVTVideoEncoderList_CodecType),
         "CodecFourCC": codecName(entry[kVTVideoEncoderList_CodecType as String]),
         "CodecName": field(entry, kVTVideoEncoderList_CodecName),
         "IsHardwareAccelerated": field(entry, kVTVideoEncoderList_IsHardwareAccelerated),
         "GPURegistryID": field(entry, kVTVideoEncoderList_GPURegistryID),
         "InstanceLimit": field(entry, kVTVideoEncoderList_InstanceLimit),
         "SupportsFrameReordering": field(entry, kVTVideoEncoderList_SupportsFrameReordering),
         "SupportedSelectionProperties": field(entry, kVTVideoEncoderList_SupportedSelectionProperties),
         "PerformanceRating": field(entry, kVTVideoEncoderList_PerformanceRating),
         "QualityRating": field(entry, kVTVideoEncoderList_QualityRating),
         "raw": entry]
    }
}

func safeFileName(_ name: String) -> String {
    String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
}

func inspect(_ entries: [[String: Any]], directory: URL) throws -> [[String: Any]] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var results: [[String: Any]] = []
    var seen = Set<String>()
    for entry in entries where codecName(entry[kVTVideoEncoderList_CodecType as String]) == "hvc1" {
        guard let id = entry[kVTVideoEncoderList_EncoderID as String] as? String else { continue }
        guard seen.insert(id).inserted else { continue }
        for (width, height) in [(1280, 720), (1920, 1080), (3840, 2160)] {
            var actualID: CFString?
            var properties: CFDictionary?
            let specification = [kVTVideoEncoderSpecification_EncoderID as String: id] as CFDictionary
            let status = VTCopySupportedPropertyDictionaryForEncoder(width: Int32(width), height: Int32(height),
                codecType: kCMVideoCodecType_HEVC, encoderSpecification: specification,
                encoderIDOut: &actualID, supportedPropertiesOut: &properties)
            let propertyMap = properties as? [String: Any] ?? [:]
            let record: [String: Any] = [
                "requestedEncoderID": id, "actualEncoderID": actualID as String? ?? NSNull() as Any,
                "width": width, "height": height, "status": status,
                "supportedProperties": propertyMap
            ]
            let path = directory.appendingPathComponent("\(safeFileName(id))-\(width)x\(height).json")
            try writeJSON(record, to: path)
            results.append(["requestedEncoderID": id, "actualEncoderID": actualID as String? ?? NSNull() as Any,
                            "width": width, "height": height, "status": status,
                            "file": path.path,
                            "BaseLayerFrameRate": propertyMap[kVTCompressionPropertyKey_BaseLayerFrameRate as String] ?? NSNull(),
                            "BaseLayerFrameRateFraction": propertyMap[kVTCompressionPropertyKey_BaseLayerFrameRateFraction as String] ?? NSNull()])
            print("\(id) \(width)x\(height): status=\(status) actual=\(actualID as String? ?? "nil") baseRate=\(propertyMap[kVTCompressionPropertyKey_BaseLayerFrameRate as String] != nil) fraction=\(propertyMap[kVTCompressionPropertyKey_BaseLayerFrameRateFraction as String] != nil)")
        }
    }
    return results
}

do {
    guard CommandLine.arguments.count == 2 else {
        fputs("Usage: EncoderCapabilityProbe <diagnostics-directory>\n", stderr)
        exit(2)
    }
    let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let before = try enumerate()
    try writeJSON(summary(before), to: directory.appendingPathComponent("vt-encoders-before.json"))
    print("before=\(before.count) HEVC=\(before.filter { codecName($0[kVTVideoEncoderList_CodecType as String]) == "hvc1" }.count)")
    VTRegisterProfessionalVideoWorkflowVideoEncoders()
    let after = try enumerate()
    try writeJSON(summary(after), to: directory.appendingPathComponent("vt-encoders-after.json"))
    try writeJSON(summary(after), to: directory.appendingPathComponent("vt-encoders.json"))
    print("after=\(after.count) HEVC=\(after.filter { codecName($0[kVTVideoEncoderList_CodecType as String]) == "hvc1" }.count)")
    let results = try inspect(after, directory: directory.appendingPathComponent("encoder-properties"))
    try writeJSON(results, to: directory.appendingPathComponent("vt-property-summary.json"))
} catch {
    fputs("EncoderCapabilityProbe failed: \(error)\n", stderr)
    exit(1)
}
