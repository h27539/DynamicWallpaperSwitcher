import Foundation
import XCTest
@testable import SwitcherCore

final class AerialLocalizationTests: XCTestCase {
    func testFullBackupPatchAndRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dws-loc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = root.appendingPathComponent("aerials/manifest/entries.json")
        let bundle = manifest.deletingLastPathComponent().appendingPathComponent("TVIdleScreenStrings.bundle")
        let table = bundle.appendingPathComponent("Contents/Resources/Localizable.nocache.loctable")
        try FileManager.default.createDirectory(at: table.deletingLastPathComponent(), withIntermediateDirectories: true)
        let baseline: [String: Any] = ["en": ["Apple": "Apple"], "zh_CN": ["Apple": "苹果"],
                                       "LocProvenance": ["Version": 1]]
        let bytes = try PropertyListSerialization.data(fromPropertyList: baseline, format: .binary, options: 0)
        try bytes.write(to: table)
        try Data("info".utf8).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        try Data("{\"assets\":[],\"categories\":[]}".utf8).write(to: manifest)
        let paths = AerialPaths(manifest: manifest, videos: root.appendingPathComponent("aerials/videos"),
                                support: root.appendingPathComponent("support"))
        let localization = AerialLocalization(paths: paths, allowTemporaryFixture: true)
        try localization.ensure()
        let status = try localization.status()
        XCTAssertTrue(status.keysPresent)
        let backup = try XCTUnwrap(status.backupPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup))
        let patched = try PropertyListSerialization.propertyList(from: Data(contentsOf: table), format: nil) as! [String: Any]
        XCTAssertEqual((patched["zh_CN"] as! [String: String])[AerialLocalization.nameKey], "自定义")
        XCTAssertEqual((patched["en"] as! [String: String])[AerialLocalization.nameKey], "Custom")
        try localization.restore()
        XCTAssertEqual(try Data(contentsOf: table), bytes)
        XCTAssertFalse(try localization.status().keysPresent)
    }
}
