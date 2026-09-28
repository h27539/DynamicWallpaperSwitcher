import Foundation
import AVFoundation
import CoreMedia

let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
let track = asset.tracks(withMediaType: .video)[0]
let reader = try AVAssetReader(asset: asset)
let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
reader.add(output)
guard reader.startReading() else { fatalError(String(describing: reader.error)) }
for i in 0..<3 {
    guard let sample = output.copyNextSampleBuffer() else { break }
    let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
    print("sample \(i): \(String(describing: array))")
}
