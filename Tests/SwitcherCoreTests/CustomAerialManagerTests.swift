import AppKit
import Foundation
import XCTest
@testable import SwitcherCore

private struct FixtureInspector: VideoInspector {
    func inspect(_ url: URL) throws -> VideoDetails {
        guard FileManager.default.fileExists(atPath: url.path) else { throw SwitcherError("源视频不存在") }
        return .init(container: url.pathExtension.uppercased(), codec: "HEVC", width: 3840, height: 2160, duration: 20, frameRate: 60)
    }

    func thumbnail(_ url: URL, to destination: URL) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.orange.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .jpeg, properties: [:])!.write(to: destination)
    }
}

final class CustomAerialManagerTests: XCTestCase {
    private var root: URL!
    private var paths: AerialPaths!
    private var manager: CustomAerialManager!
    private var source: URL!
    private let blueID = "94383DC9-59D3-43EC-9E8E-A783DA633E06"
    private let macID = CustomAerialManager.macCategoryID
    private let nativeSubID = CustomAerialManager.macSubcategoryID
    private let customSubID = CustomAerialManager.customSubcategoryID

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dws-custom-\(UUID().uuidString)")
        paths = .init(manifest: root.appendingPathComponent("aerials/manifest/entries.json"),
                      videos: root.appendingPathComponent("aerials/videos"),
                      support: root.appendingPathComponent("support"))
        try FileManager.default.createDirectory(at: paths.manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.videos, withIntermediateDirectories: true)
        try writeManifest([
            "futureUnknownField": ["keep": true],
            "assets": [
                ["id": blueID, "shotID": "MAC_BLUE", "localizedNameKey": "MAC_WP_BLU_NAME",
                 "categories": [macID], "subcategories": [nativeSubID], "preferredOrder": 81,
                 "previewImage": "https://example.apple.com/blue.png",
                 "url-4K-SDR-240FPS": "https://example.apple.com/blue.mov"],
                ["id": "OTHER", "shotID": "OTHER", "categories": [macID], "unknown": 42]
            ],
            "categories": [
                ["id": macID, "localizedNameKey": "MAC", "representativeAssetID": blueID,
                 "previewImage": "https://example.apple.com/mac.png", "preferredOrder": 5,
                 "subcategories": [["id": nativeSubID, "localizedNameKey": "Blue"],
                                   ["id": "GOLDEN-GATE", "localizedNameKey": "Golden Gate"]]],
                ["id": "OTHER-CATEGORY", "unknown": "keep"]
            ]
        ])
        source = root.appendingPathComponent("source.mov")
        try Data("fixture-video".utf8).write(to: source)
        manager = .init(paths: paths, inspector: FixtureInspector())
    }

    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    func testImportCreatesOnlyMacSubcategoryAndPNG() throws {
        let before = try readManifest()
        let macBefore = try mac(before)
        let asset = try manager.importVideo(source, displayName: "Tokyo Night")
        XCTAssertEqual(asset.mode, .custom)
        XCTAssertEqual(asset.categoryID, customSubID)
        let after = try readManifest()
        let macAfter = try mac(after)
        for field in ["id", "localizedNameKey", "representativeAssetID", "previewImage", "preferredOrder"] {
            XCTAssertEqual(String(describing: macAfter[field]), String(describing: macBefore[field]))
        }
        let subs = macAfter["subcategories"] as! [[String: Any]]
        XCTAssertEqual(subs.count, 3)
        XCTAssertEqual(subs[0]["id"] as? String, nativeSubID)
        XCTAssertEqual(subs[1]["id"] as? String, "GOLDEN-GATE")
        XCTAssertEqual(subs[2]["id"] as? String, customSubID)
        XCTAssertEqual(subs[2]["representativeAssetID"] as? String, asset.id)
        let entry = try XCTUnwrap((after["assets"] as! [[String: Any]]).first { $0["id"] as? String == asset.id })
        XCTAssertEqual(entry["categories"] as? [String], [macID])
        XCTAssertEqual(entry["subcategories"] as? [String], [customSubID])
        XCTAssertEqual(entry["preferredOrder"] as? Int, 0)
        XCTAssertEqual(entry["previewImage"] as? String, "https://example.apple.com/blue.png")
        XCTAssertEqual(entry["url-4K-SDR-240FPS"] as? String, "https://example.apple.com/blue.mov")
        let png = paths.thumbnails.appendingPathComponent(asset.id + ".png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: png)))
        XCTAssertEqual(bitmap.pixelsWide, 356)
        XCTAssertEqual(bitmap.pixelsHigh, 356)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.thumbnails.appendingPathComponent(asset.id + ".jpg").path))
        XCTAssertTrue(try XCTUnwrap(manager.list().first).isHealthy)
        XCTAssertEqual((after["futureUnknownField"] as? [String: Bool])?["keep"], true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.support.appendingPathComponent("Backups").path))
    }

    func testTimestampedBackupRetentionKeepsIndependentRecoverySnapshots() throws {
        let backups = paths.support.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let protected = backups.appendingPathComponent("entries-before-x265-poc-snapshot.json")
        try Data("recovery".utf8).write(to: protected)
        for index in 0..<11 {
            try Data("old".utf8).write(to: backups.appendingPathComponent("entries-\(1000 + index)-\(UUID().uuidString).json"))
        }
        _ = try manager.importVideo(source, displayName: "Backup retention")
        XCTAssertEqual(try Data(contentsOf: protected), Data("recovery".utf8))
        let names = try FileManager.default.contentsOfDirectory(atPath: backups.path)
        XCTAssertEqual(names.filter { $0.hasPrefix("entries-") && !$0.hasPrefix("entries-before-") }.count, 10)
        XCTAssertTrue(names.contains { name in
            let parts = name.split(separator: "-", maxSplits: 2)
            return parts.count == 3 && (Int(parts[1]) ?? 0) > 1_700_000_000
        })
    }

    func testValidatedImportCreatesOneFormalCategoryOnFirstAndSecondImport() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let movie = project.appendingPathComponent("diagnostics/sample_video-aerial-1080p.mov")
        guard FileManager.default.fileExists(atPath: movie.path) else { throw XCTSkip("参考 MOV 不在本地项目") }
        let formal = CustomAerialManager(paths: paths, inspector: FixtureInspector(),
                                         ensureLocalizationOverride: {})
        let first = try formal.importConvertedVideo(movie, sourceFilename: "sample_video.mp4", displayName: "第一张")
        let second = try formal.importConvertedVideo(movie, sourceFilename: "sample_video.mp4", displayName: "第二张")
        XCTAssertTrue(first.compatibilityValidated)
        XCTAssertTrue(second.compatibilityValidated)
        XCTAssertEqual(first.categoryID, CustomAerialManager.formalCategoryID)
        XCTAssertEqual(second.categoryID, CustomAerialManager.formalCategoryID)
        let root = try readManifest()
        let formalCategories = (root["categories"] as! [[String: Any]]).filter {
            $0["id"] as? String == CustomAerialManager.formalCategoryID
        }
        XCTAssertEqual(formalCategories.count, 1)
        let created = (root["assets"] as! [[String: Any]]).filter {
            [first.id, second.id].contains($0["id"] as? String ?? "")
        }
        XCTAssertEqual(created.count, 2)
        XCTAssertTrue(created.allSatisfy { $0["categories"] as? [String] == [CustomAerialManager.formalCategoryID] })
    }

    func testFormalCategoryMovesOnlyOwnedCustomAssetsAndRemovesAfterLastDeletion() throws {
        let formal = CustomAerialManager(paths: paths, inspector: FixtureInspector(),
                                         ensureLocalizationOverride: {})
        let first = try formal.importVideo(source, displayName: "First")
        let second = try formal.importVideo(source, displayName: "Second")
        try formal.activateFormalCustomCategory()
        let migrated = try readManifest()
        let categories = migrated["categories"] as! [[String: Any]]
        let formalCategory = try XCTUnwrap(categories.first {
            $0["id"] as? String == CustomAerialManager.formalCategoryID
        })
        XCTAssertEqual(formalCategory["representativeAssetID"] as? String, first.id)
        XCTAssertEqual(formalCategory["localizedNameKey"] as? String, AerialLocalization.nameKey)
        let moved = (migrated["assets"] as! [[String: Any]]).filter {
            [first.id, second.id].contains($0["id"] as? String ?? "")
        }
        XCTAssertEqual(moved.count, 2)
        XCTAssertTrue(moved.allSatisfy { $0["categories"] as? [String] == [CustomAerialManager.formalCategoryID] })
        XCTAssertTrue(moved.allSatisfy { $0["subcategories"] as? [String] == [CustomAerialManager.formalSubcategoryID] })
        XCTAssertEqual((try formal.list()).filter(\.isHealthy).count, 2)
        try formal.delete(first.id)
        let afterFirst = try readManifest()
        let rep = (afterFirst["categories"] as! [[String: Any]]).first {
            $0["id"] as? String == CustomAerialManager.formalCategoryID
        }?["representativeAssetID"] as? String
        XCTAssertEqual(rep, second.id)
        try formal.delete(second.id)
        let afterLast = try readManifest()
        XCTAssertFalse((afterLast["categories"] as! [[String: Any]]).contains {
            $0["id"] as? String == CustomAerialManager.formalCategoryID
        })
        XCTAssertTrue((afterLast["assets"] as! [[String: Any]]).contains { $0["id"] as? String == blueID })
    }

    func testDeleteRepresentativeThenLastPreservesAppleAndGoldenGate() throws {
        let first = try manager.importVideo(source)
        let second = try manager.importVideo(source)
        try manager.delete(first.id)
        let afterFirst = try readManifest()
        let sub = (try mac(afterFirst)["subcategories"] as! [[String: Any]]).last!
        XCTAssertEqual(sub["representativeAssetID"] as? String, second.id)
        try manager.delete(second.id)
        let afterLast = try readManifest()
        let subs = try mac(afterLast)["subcategories"] as! [[String: Any]]
        XCTAssertEqual(subs.map { $0["id"] as? String }, [nativeSubID, "GOLDEN-GATE"])
        XCTAssertEqual((afterLast["assets"] as! [[String: Any]]).count, 2)
    }

    func testRepairRestoresCachePNGAssetAndSubcategory() throws {
        let asset = try manager.importVideo(source)
        try FileManager.default.removeItem(at: paths.videos.appendingPathComponent(asset.id + ".mov"))
        try FileManager.default.removeItem(at: paths.thumbnails.appendingPathComponent(asset.id + ".png"))
        var root = try readManifest()
        root["assets"] = (root["assets"] as! [[String: Any]]).filter { $0["id"] as? String != asset.id }
        var categories = root["categories"] as! [[String: Any]]
        var subs = categories[0]["subcategories"] as! [[String: Any]]
        subs.removeLast()
        categories[0]["subcategories"] = subs
        root["categories"] = categories
        try writeManifest(root)
        try manager.repair(asset.id)
        XCTAssertTrue(try XCTUnwrap(manager.list().first).isHealthy)
        XCTAssertEqual((try mac(readManifest())["subcategories"] as! [[String: Any]]).count, 3)
    }

    func testRejectsMP4AndUnownedDeletion() throws {
        let mp4 = root.appendingPathComponent("sample.mp4")
        try Data("bytes".utf8).write(to: mp4)
        XCTAssertThrowsError(try manager.importVideo(mp4))
        XCTAssertThrowsError(try manager.delete("OTHER"))
        XCTAssertEqual((try readManifest()["assets"] as! [[String: Any]]).count, 2)
    }

    func testConcurrentManifestChangeIsPreserved() throws {
        let modified = CustomAerialManager(paths: paths, inspector: FixtureInspector(), beforeManifestCommit: {
            var root = try self.readManifest()
            root["concurrent"] = "retain"
            try self.writeManifest(root)
        })
        XCTAssertThrowsError(try modified.importVideo(source))
        XCTAssertEqual(try readManifest()["concurrent"] as? String, "retain")
    }

    func testRepairCorrectsInvalidRepresentative() throws {
        let asset = try manager.importVideo(source)
        var root = try readManifest()
        var categories = root["categories"] as! [[String: Any]]
        var subs = categories[0]["subcategories"] as! [[String: Any]]
        subs[2]["representativeAssetID"] = "MISSING"
        categories[0]["subcategories"] = subs
        root["categories"] = categories
        try writeManifest(root)
        try manager.repair(asset.id)
        let repaired = try mac(readManifest())["subcategories"] as! [[String: Any]]
        XCTAssertEqual(repaired[2]["representativeAssetID"] as? String, asset.id)
    }

    func testExplicitLegacyMigrationKeepsUUIDAndOriginal() throws {
        let id = "E58A9137-9A14-48D5-9D63-024059C837C0"
        let dir = paths.support.appendingPathComponent("CustomAerials/Assets/\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = dir.appendingPathComponent("original.mov")
        try FileManager.default.copyItem(at: source, to: original)
        try FixtureInspector().thumbnail(original, to: dir.appendingPathComponent("thumbnail.jpg"))
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        task.arguments = ["-a", "256", source.path]
        task.standardOutput = output
        try task.run(); task.waitUntilExit()
        let sha = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: " ")[0]
        let metadata: [String: Any] = ["version": 1, "assets": [[
            "id": id, "shotID": "CUSTOM_OLD_LONG", "displayName": "旧壁纸",
            "sourceFilename": "source.mov", "createdAt": "2026-09-24T00:00:00Z",
            "videoSHA256": String(sha), "categoryID": customSubID,
            "details": ["container": "MOV", "codec": "HEVC", "width": 3840, "height": 2160,
                        "duration": 20.0, "frameRate": 60.0]
        ]]]
        try JSONSerialization.data(withJSONObject: metadata).write(to: paths.support.appendingPathComponent("CustomAerials/metadata.json"))
        var root = try readManifest()
        var categories = root["categories"] as! [[String: Any]]
        categories.append(["id": customSubID, "localizedNameKey": "自定义", "subcategories": []])
        root["categories"] = categories
        var assets = root["assets"] as! [[String: Any]]
        assets.append(["id": id, "shotID": "CUSTOM_OLD_LONG", "categories": [customSubID], "subcategories": []])
        root["assets"] = assets
        try writeManifest(root)
        let originalBytes = try Data(contentsOf: original)
        try manager.migrateLegacy(id)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        let migrated = try readManifest()
        let entry = try XCTUnwrap((migrated["assets"] as! [[String: Any]]).first { $0["id"] as? String == id })
        XCTAssertEqual(entry["shotID"] as? String, "CUSTOM_E58A9137")
        XCTAssertEqual(entry["subcategories"] as? [String], [customSubID])
        XCTAssertFalse((migrated["categories"] as! [[String: Any]]).contains { $0["id"] as? String == customSubID })
        XCTAssertEqual(try XCTUnwrap(manager.list().first).asset.mode, .custom)
    }

    private func mac(_ root: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap((root["categories"] as! [[String: Any]]).first { $0["id"] as? String == macID })
    }

    private func readManifest() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: paths.manifest)) as? [String: Any])
    }

    private func writeManifest(_ root: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: root).write(to: paths.manifest, options: .atomic)
    }
}
