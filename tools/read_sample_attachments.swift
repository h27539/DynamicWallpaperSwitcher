import Foundation
import AVFoundation
import CoreMedia

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let asset = AVURLAsset(url: url)
guard let track = asset.tracks(withMediaType: .video).first else { fatalError("No video track") }
let reader = try AVAssetReader(asset: asset)
let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
output.alwaysCopiesSampleData = false
reader.add(output)
guard reader.startReading() else { fatalError("Cannot start reader: \(String(describing: reader.error))") }

let levelKey = kCMSampleAttachmentKey_HEVCTemporalLevelInfo as String
let temporalKey = kCMHEVCTemporalLevelInfoKey_TemporalLevel as String
let tsaKey = kCMSampleAttachmentKey_HEVCTemporalSubLayerAccess as String
let stsaKey = kCMSampleAttachmentKey_HEVCStepwiseTemporalSubLayerAccess as String
var levelCounts: [String: Int] = [:]
var tsaCount = 0
var stsaCount = 0
var examples: [String] = []
var csvRows: [String] = ["sample,temporal_level,tsas,stsa"]
var sampleIndex = 0
var attachmentIndex = 0
var tsaByLevel: [String: Int] = [:]
while let sample = output.copyNextSampleBuffer() {
    sampleIndex += 1
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]] ?? []
    for attachment in attachments {
        attachmentIndex += 1
        let levelInfo = attachment[levelKey] as? [String: Any]
        let level = levelInfo?[temporalKey]
        let label = level.map { String(describing: $0) } ?? "absent"
        levelCounts[label, default: 0] += 1
        if attachment[tsaKey] != nil { tsaCount += 1; tsaByLevel[label, default: 0] += 1 }
        if attachment[stsaKey] != nil { stsaCount += 1 }
        csvRows.append("\(attachmentIndex),\(label),\(attachment[tsaKey] != nil ? 1 : 0),\(attachment[stsaKey] != nil ? 1 : 0)")
        if examples.count < 64 {
            examples.append("sample=\(attachmentIndex) temporalLevel=\(label) tsas=\(attachment[tsaKey] ?? "absent") stsa=\(attachment[stsaKey] ?? "absent")")
        }
    }
}
print("file=\(url.path)")
print("samples=\(sampleIndex) readerStatus=\(reader.status.rawValue) error=\(String(describing: reader.error))")
print("temporalLevelCounts=\(levelCounts)")
print("attachmentSamples=\(attachmentIndex) tsasByLevel=\(tsaByLevel)")
print("tsasAttachmentCount=\(tsaCount) stsaAttachmentCount=\(stsaCount)")
print(examples.joined(separator: "\n"))
if CommandLine.arguments.count > 2 {
    try csvRows.joined(separator: "\n").write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
}
