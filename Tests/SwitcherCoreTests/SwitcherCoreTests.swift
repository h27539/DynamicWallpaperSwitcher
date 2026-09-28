import Foundation
import CryptoKit
import XCTest
@testable import SwitcherCore

final class SwitcherCoreTests: XCTestCase {
    private var root: URL!
    private var paths: SwitcherPaths!
    private var switcher: WallpaperSwitcher!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = SwitcherPaths(
            videos: root.appendingPathComponent("container/Videos"),
            support: root.appendingPathComponent("support"),
            aerials: root.appendingPathComponent("aerials")
        )
        try FileManager.default.createDirectory(at: paths.videos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.aerials, withIntermediateDirectories: true)
        for (index, name) in WallpaperFile.allCases.enumerated() {
            try movie("tahoe-\(index)").write(to: paths.videos.appendingPathComponent(name.rawValue))
        }
        let trusted = Dictionary(uniqueKeysWithValues: WallpaperFile.allCases.enumerated().map { index, file in
            (file, SHA256.hash(data: movie("tahoe-\(index)")).map { String(format: "%02x", $0) }.joined())
        })
        switcher = WallpaperSwitcher(paths: paths, trustedTahoeHashes: trusted)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testFirstRunBacksUpAllFourAndRecognizesTahoe() throws {
        try switcher.prepare()
        XCTAssertEqual(try switcher.status(), .tahoe)
        for name in WallpaperFile.allCases {
            XCTAssertEqual(try Data(contentsOf: paths.support.appendingPathComponent("Tahoe/\(name.rawValue)")),
                           try Data(contentsOf: paths.videos.appendingPathComponent(name.rawValue)))
        }
    }

    func testGoldenGateSwitchKeepsTahoePortraitAndCanRestore() throws {
        try switcher.prepare()
        try movie("golden-light").write(to: paths.aerials.appendingPathComponent(WallpaperFile.lightLandscape.aerialID! + ".mov"))
        try movie("golden-dark").write(to: paths.aerials.appendingPathComponent(WallpaperFile.darkLandscape.aerialID! + ".mov"))
        let portrait = try Data(contentsOf: paths.videos.appendingPathComponent(WallpaperFile.lightPortrait.rawValue))
        try switcher.switchTo(.goldenGate)
        XCTAssertEqual(try switcher.status(), .goldenGate)
        XCTAssertEqual(try Data(contentsOf: paths.videos.appendingPathComponent(WallpaperFile.lightPortrait.rawValue)), portrait)
        try switcher.switchTo(.tahoe)
        XCTAssertEqual(try switcher.status(), .tahoe)
    }

    func testUnknownStateDoesNotOverwriteTahoeBackup() throws {
        try switcher.prepare()
        let backup = try Data(contentsOf: paths.support.appendingPathComponent("Tahoe/\(WallpaperFile.lightLandscape.rawValue)"))
        try movie("other").write(to: paths.videos.appendingPathComponent(WallpaperFile.lightLandscape.rawValue))
        XCTAssertEqual(try switcher.status(), .unknown)
        try switcher.prepare()
        XCTAssertEqual(try Data(contentsOf: paths.support.appendingPathComponent("Tahoe/\(WallpaperFile.lightLandscape.rawValue)")), backup)
    }

    func testMissingGoldenGateSourceLeavesVideosUntouched() throws {
        try switcher.prepare()
        let original = try Data(contentsOf: paths.videos.appendingPathComponent(WallpaperFile.lightLandscape.rawValue))
        XCTAssertThrowsError(try switcher.switchTo(.goldenGate))
        XCTAssertEqual(try Data(contentsOf: paths.videos.appendingPathComponent(WallpaperFile.lightLandscape.rawValue)), original)
    }

    func testResetRestoresTahoeAndPreservesUserPortraitAssets() throws {
        try switcher.prepare()
        try movie("golden-light").write(to: paths.aerials.appendingPathComponent(WallpaperFile.lightLandscape.aerialID! + ".mov"))
        try movie("golden-dark").write(to: paths.aerials.appendingPathComponent(WallpaperFile.darkLandscape.aerialID! + ".mov"))
        let portrait = paths.support.appendingPathComponent("GoldenGate/Light Portrait.mov")
        try FileManager.default.createDirectory(at: portrait.deletingLastPathComponent(), withIntermediateDirectories: true)
        try movie("portrait").write(to: portrait)
        try switcher.switchTo(.goldenGate)
        try switcher.reset()
        XCTAssertEqual(try switcher.status(), .tahoe)
        XCTAssertTrue(FileManager.default.fileExists(atPath: portrait.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.support.appendingPathComponent("GoldenGate/Light Landscape.mov").path))
    }

    func testUntrustedTahoeHashRefusesFirstBackup() throws {
        let strict = WallpaperSwitcher(paths: paths)
        XCTAssertThrowsError(try strict.prepare())
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.support.appendingPathComponent("Tahoe/backup-sha256.json").path))
    }

    func testInterruptedTransactionIsDetectedAndRecovered() throws {
        try switcher.prepare()
        let file = WallpaperFile.lightLandscape.rawValue
        let before = try Data(contentsOf: paths.videos.appendingPathComponent(file))
        let transaction = paths.support.appendingPathComponent(".transaction-test")
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
        try before.write(to: transaction.appendingPathComponent(file))
        let hash = SHA256.hash(data: before).map { String(format: "%02x", $0) }.joined()
        try JSONEncoder().encode([file: hash]).write(to: transaction.appendingPathComponent("preimage-sha256.json"))
        try movie("changed").write(to: paths.videos.appendingPathComponent(file))
        XCTAssertThrowsError(try switcher.prepare())
        try switcher.recoverInterrupted()
        XCTAssertEqual(try Data(contentsOf: paths.videos.appendingPathComponent(file)), before)
        XCTAssertTrue(switcher.pendingTransactions().isEmpty)
    }

    func testTamperedGoldenCacheIsNotRecognized() throws {
        try switcher.prepare()
        try movie("golden-light").write(to: paths.aerials.appendingPathComponent(WallpaperFile.lightLandscape.aerialID! + ".mov"))
        try movie("golden-dark").write(to: paths.aerials.appendingPathComponent(WallpaperFile.darkLandscape.aerialID! + ".mov"))
        try switcher.switchTo(.goldenGate)
        let cached = paths.support.appendingPathComponent("GoldenGate/Light Landscape.mov")
        try movie("tampered").write(to: cached)
        XCTAssertEqual(try switcher.status(), .goldenGate) // The still-available original Aerials file verifies the live video.
        try FileManager.default.removeItem(at: paths.aerials.appendingPathComponent(WallpaperFile.lightLandscape.aerialID! + ".mov"))
        XCTAssertEqual(try switcher.status(), .unknown)
    }

    private func movie(_ label: String) -> Data {
        Data([0, 0, 0, 20] + Array("ftypqt  \(label)".utf8))
    }
}
