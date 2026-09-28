import AppKit
import AVFoundation
import CryptoKit
import Darwin
import Foundation

public struct AerialPaths {
    public let manifest: URL
    public let videos: URL
    public let thumbnails: URL
    public let support: URL

    public init(manifest: URL, videos: URL, support: URL) {
        self.manifest = manifest
        self.videos = videos
        self.thumbnails = videos.deletingLastPathComponent().appendingPathComponent("thumbnails")
        self.support = support
    }

    public static var userDefault: AerialPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials")
        return .init(manifest: root.appendingPathComponent("manifest/entries.json"),
                     videos: root.appendingPathComponent("videos"),
                     support: home.appendingPathComponent("Library/Application Support/DynamicWallpaperSwitcher"))
    }
}

public struct VideoDetails: Codable, Equatable {
    public let container: String
    public let codec: String
    public let width: Int
    public let height: Int
    public let duration: Double
    public let frameRate: Double

    public init(container: String, codec: String, width: Int, height: Int, duration: Double, frameRate: Double) {
        self.container = container; self.codec = codec; self.width = width; self.height = height
        self.duration = duration; self.frameRate = frameRate
    }

    public var summary: String { "\(codec) · \(width)×\(height) · \(Int(frameRate.rounded())) fps" }
    public var isTypicalAerial: Bool { container == "MOV" && codec == "HEVC" && width >= 1920 && height >= 1080 }
}

public protocol VideoInspector {
    func inspect(_ url: URL) throws -> VideoDetails
    func thumbnail(_ url: URL, to destination: URL) throws
}

public protocol VideoTranscoder {
    func transcode(_ source: URL, to destination: URL) throws
}

public struct AVFoundationVideoInspector: VideoInspector {
    public init() {}

    public func inspect(_ url: URL) throws -> VideoDetails {
        let ext = url.pathExtension.lowercased()
        guard ext == "mov" || ext == "mp4" else { throw SwitcherError("仅支持 MOV 或 MP4 视频。") }
        let asset = AVURLAsset(url: url)
        guard asset.isReadable, asset.isPlayable, let track = asset.tracks(withMediaType: .video).first else {
            throw SwitcherError("AVFoundation 无法读取视频轨道：\(url.lastPathComponent)")
        }
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite && seconds > 0 else { throw SwitcherError("视频时长无效。") }
        let size = track.naturalSize.applying(track.preferredTransform)
        let subtype = track.formatDescriptions.first.map { CMFormatDescriptionGetMediaSubType($0 as! CMFormatDescription) } ?? 0
        let codec: String
        switch subtype {
        case 0x68766331, 0x68657631: codec = "HEVC" // hvc1 / hev1
        case 0x61766331: codec = "H.264" // avc1
        default:
            let bytes = [24, 16, 8, 0].map { UInt8((subtype >> $0) & 0xff) }
            codec = String(bytes: bytes, encoding: .ascii) ?? "未知"
        }
        return VideoDetails(container: ext.uppercased(), codec: codec,
                            width: Int(abs(size.width)), height: Int(abs(size.height)),
                            duration: seconds, frameRate: Double(track.nominalFrameRate))
    }

    public func thumbnail(_ url: URL, to destination: URL) throws {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        let time = CMTime(seconds: min(1, seconds * 0.1), preferredTimescale: 600)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 520, height: 320)
        let frame = try generator.copyCGImage(at: time, actualTime: nil)
        let bitmap = NSBitmapImageRep(cgImage: frame)
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else {
            throw SwitcherError("无法生成视频缩略图。")
        }
        try jpeg.write(to: destination, options: .atomic)
    }
}

public enum CustomAssetMode: String, Codable {
    case custom, experimental, legacy
}

public struct CustomAerialAsset: Codable, Identifiable {
    public let id: String
    public let shotID: String
    public let displayName: String
    public let sourceFilename: String
    public let createdAt: Date
    public let videoSHA256: String
    public let categoryID: String
    public let details: VideoDetails
    public let mode: CustomAssetMode
    public let compatibilityValidated: Bool

    public init(id: String, shotID: String, displayName: String, sourceFilename: String,
                createdAt: Date, videoSHA256: String, categoryID: String,
                details: VideoDetails, mode: CustomAssetMode, compatibilityValidated: Bool = false) {
        self.id = id; self.shotID = shotID; self.displayName = displayName
        self.sourceFilename = sourceFilename; self.createdAt = createdAt
        self.videoSHA256 = videoSHA256; self.categoryID = categoryID
        self.details = details; self.mode = mode; self.compatibilityValidated = compatibilityValidated
    }

    private enum CodingKeys: String, CodingKey {
        case id, shotID, displayName, sourceFilename, createdAt, videoSHA256, categoryID, details, mode, compatibilityValidated
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(String.self, forKey: .id)
        shotID = try box.decode(String.self, forKey: .shotID)
        displayName = try box.decode(String.self, forKey: .displayName)
        sourceFilename = try box.decode(String.self, forKey: .sourceFilename)
        createdAt = try box.decode(Date.self, forKey: .createdAt)
        videoSHA256 = try box.decode(String.self, forKey: .videoSHA256)
        categoryID = try box.decode(String.self, forKey: .categoryID)
        details = try box.decode(VideoDetails.self, forKey: .details)
        mode = try box.decodeIfPresent(CustomAssetMode.self, forKey: .mode)
            ?? (categoryID == CustomAerialManager.macCategoryID ? .experimental : .legacy)
        compatibilityValidated = try box.decodeIfPresent(Bool.self, forKey: .compatibilityValidated) ?? false
    }
}

public struct CustomAssetHealth: Identifiable {
    public let asset: CustomAerialAsset
    public let manifestPresent: Bool
    public let cachePresent: Bool
    public let originalPresent: Bool
    public let thumbnailPresent: Bool
    public let hashMatches: Bool
    public var id: String { asset.id }
    public var isHealthy: Bool { manifestPresent && cachePresent && originalPresent && thumbnailPresent && hashMatches }
}

private struct OwnedAssets: Codable {
    var version = 1
    var assets: [CustomAerialAsset] = []
}

public struct ManifestDiagnosticStatus {
    public let controlActive: Bool
    public let controlConfirmed: Bool
    public let cloneID: String?
    public let backupPath: String?
}

private struct ManifestControlRecord: Codable {
    var backupFilename: String
    var active: Bool
    var confirmed: Bool
}

private struct ManifestCloneRecord: Codable {
    var id: String
    var shotID: String
    var thumbnailSHA256: String?
}

private struct POCLedger: Decodable {
    let id: String
    let shotID: String
    let videoSHA256: String
    let thumbnailSHA256: String
}

public struct CustomAerialManager {
    public static let categoryID = "D8C9A42E-12F7-4DA5-8B04-8E25F9530D77" // Legacy top-level ID; now the custom subcategory ID.
    public static let customSubcategoryID = categoryID
    public static let formalCategoryID = "560E9B69-1F56-4B6E-84A4-07BC20205954"
    public static let formalSubcategoryID = "7300EB79-C3D2-4195-9433-34F9FD0E3ABB"
    public static let macCategoryID = "8048287A-39E6-4093-87EC-B0DCE7CB4A29"
    public static let macSubcategoryID = "989909D1-AEFC-4BE5-9249-ABFBA5CABED0"
    private static let knownMacAssetID = "94383DC9-59D3-43EC-9E8E-A783DA633E06"
    public let paths: AerialPaths
    private let inspector: VideoInspector
    private let beforeManifestCommit: (() throws -> Void)?
    private let ensureLocalizationOverride: (() throws -> Void)?
    private let fm = FileManager.default
    private var customRoot: URL { paths.support.appendingPathComponent("CustomAerials") }
    private var assetsRoot: URL { customRoot.appendingPathComponent("Assets") }
    private var metadataURL: URL { customRoot.appendingPathComponent("metadata.json") }
    private var backupRoot: URL { paths.support.appendingPathComponent("Backups") }
    private var diagnosticRoot: URL { paths.support.appendingPathComponent("ManifestDiagnostics") }
    private var controlRecordURL: URL { diagnosticRoot.appendingPathComponent("mac-blue-control.json") }
    private var cloneRecordURL: URL { diagnosticRoot.appendingPathComponent("mac-blue-clone.json") }

    public init(paths: AerialPaths = .userDefault, inspector: VideoInspector = AVFoundationVideoInspector(),
                beforeManifestCommit: (() throws -> Void)? = nil,
                ensureLocalizationOverride: (() throws -> Void)? = nil) {
        self.paths = paths; self.inspector = inspector; self.beforeManifestCommit = beforeManifestCommit
        self.ensureLocalizationOverride = ensureLocalizationOverride
    }

    private func ensureLocalization() throws {
        if let ensureLocalizationOverride { try ensureLocalizationOverride() }
        else { try AerialLocalization(paths: paths).ensure() }
    }

    public func inspect(_ source: URL) throws -> VideoDetails { try inspector.inspect(source) }

    public func localizationStatus() throws -> AerialLocalizationStatus {
        try AerialLocalization(paths: paths).status()
    }

    public func repairCustomCategoryLocalization() throws {
        try ensureLocalization()
    }

    public func restoreOriginalLocalization() throws {
        try AerialLocalization(paths: paths).restore()
    }

    /// Explicit developer cleanup. Only the three bundled ownership ledgers are accepted.
    public func cleanupVerifiedPOCCards() throws -> Int {
        let owned = try readOwned()
        guard owned.assets.contains(where: {
            $0.mode == .custom && $0.categoryID == Self.formalCategoryID
                && $0.compatibilityValidated && $0.sourceFilename == "sample_video.mp4"
        }) else {
            throw SwitcherError("请先用新版 App 成功导入 sample_video.mp4，再清理三张 POC 卡。")
        }
        let names = ["sample_video-4k-poc-ledger", "sample_video-4k-hq-poc-ledger", "sample_video-4k-full-poc-ledger"]
        let ledgers = try names.map { name -> POCLedger in
            guard let url = Bundle.main.url(forResource: name, withExtension: "json") else {
                throw SwitcherError("App 缺少 POC 所有权记录：\(name)。")
            }
            return try JSONDecoder().decode(POCLedger.self, from: Data(contentsOf: url))
        }
        let manifest = try readManifest()
        let entries = try assetArray(manifest)
        guard (try categoryArray(manifest)).contains(where: { $0["id"] as? String == Self.macCategoryID }),
              entries.contains(where: { $0["id"] as? String == Self.knownMacAssetID }) else {
            throw SwitcherError("当前 Aerials 目录缺少系统 Mac 分类或 Mac Blue；停止清理，请先恢复目录。")
        }
        for ledger in ledgers {
            let matches = entries.filter { $0["id"] as? String == ledger.id }
            guard matches.count <= 1, matches.first?["shotID"] as? String == ledger.shotID || matches.isEmpty else {
                throw SwitcherError("POC 资源归属不匹配：\(ledger.id)。")
            }
            for (path, expected) in [(cacheURL(ledger.id), ledger.videoSHA256),
                                     (thumbnailPNGURL(ledger.id), ledger.thumbnailSHA256)] {
                if fm.fileExists(atPath: path.path) {
                    guard try sha256(path) == expected else {
                        throw SwitcherError("POC 文件哈希已变化，拒绝删除：\(path.path)")
                    }
                }
            }
        }
        let ids = Set(ledgers.map(\.id))
        let count = entries.filter { ids.contains($0["id"] as? String ?? "") }.count
        if count > 0 {
            try mutateManifest { root in
                var assets = try assetArray(root)
                for ledger in ledgers {
                    let matches = assets.filter { $0["id"] as? String == ledger.id }
                    guard matches.count <= 1,
                          matches.first?["shotID"] as? String == ledger.shotID || matches.isEmpty else {
                        throw SwitcherError("POC 删除前 manifest 发生变化。")
                    }
                }
                assets.removeAll { ids.contains($0["id"] as? String ?? "") }
                root["assets"] = assets
            }
        }
        for ledger in ledgers {
            for path in [cacheURL(ledger.id), thumbnailPNGURL(ledger.id)] where fm.fileExists(atPath: path.path) {
                try fm.removeItem(at: path)
            }
        }
        return count
    }

    public func activateFormalCustomCategory() throws {
        var owned = try readOwned()
        let selected = owned.assets.filter { $0.mode == .custom }
        guard !selected.isEmpty else { throw SwitcherError("请先导入至少一张自定义壁纸，再创建独立分类。") }
        let original = try readManifest()
        guard !(try categoryArray(original)).contains(where: { $0["id"] as? String == Self.formalCategoryID }) else {
            throw SwitcherError("独立自定义分类已经存在。")
        }
        let entries = try assetArray(original)
        for asset in selected {
            guard let entry = entries.first(where: { $0["id"] as? String == asset.id }),
                  entry["shotID"] as? String == asset.shotID,
                  entry["categories"] as? [String] == [Self.macCategoryID],
                  entry["subcategories"] as? [String] == [Self.customSubcategoryID] else {
                throw SwitcherError("现有自定义资源与 App 元数据不一致；先修复后再迁移分类。")
            }
        }
        try ensureLocalization()
        let previous = owned
        owned.assets = owned.assets.map { asset in
            guard asset.mode == .custom else { return asset }
            return CustomAerialAsset(id: asset.id, shotID: asset.shotID, displayName: asset.displayName,
                sourceFilename: asset.sourceFilename, createdAt: asset.createdAt,
                videoSHA256: asset.videoSHA256, categoryID: Self.formalCategoryID,
                details: asset.details, mode: asset.mode,
                compatibilityValidated: asset.compatibilityValidated)
        }
        try writeOwned(owned)
        do {
            try mutateManifest { root in
                var assets = try assetArray(root)
                for asset in selected {
                    guard let index = assets.firstIndex(where: { $0["id"] as? String == asset.id }) else {
                        throw SwitcherError("迁移期间资源消失。")
                    }
                    assets[index]["categories"] = [Self.formalCategoryID]
                    assets[index]["subcategories"] = [Self.formalSubcategoryID]
                    assets[index]["showInTopLevel"] = true
                }
                root["assets"] = assets
                try updateFormalCategory(in: &root, ownedIDs: Set(selected.map(\.id)))
                try updateCustomSubcategory(in: &root, ownedIDs: [])
            }
        } catch {
            try? writeOwned(previous)
            throw error
        }
    }

    public func manifestDiagnosticStatus() throws -> ManifestDiagnosticStatus {
        let control = try readControlRecord()
        let clone = try readCloneRecord()
        return ManifestDiagnosticStatus(controlActive: control?.active ?? false,
                                        controlConfirmed: control?.confirmed ?? false,
                                        cloneID: clone?.id,
                                        backupPath: control.map { diagnosticRoot.appendingPathComponent($0.backupFilename).path })
    }

    @discardableResult
    public func beginManifestControlTest() throws -> String {
        if try readControlRecord()?.active == true { throw SwitcherError("Mac Blue 控制测试已在进行；请先观察或恢复。") }
        if try readCloneRecord() != nil { throw SwitcherError("请先删除本 App 的 Mac Blue 克隆测试 asset。") }
        let baseline = try Data(contentsOf: paths.manifest)
        let root = try readManifest()
        _ = try controlExpectedRoot(root)
        try fm.createDirectory(at: diagnosticRoot, withIntermediateDirectories: true)
        let filename = "entries-before-mac-blue-\(UUID().uuidString).json"
        let backup = diagnosticRoot.appendingPathComponent(filename)
        try baseline.write(to: backup, options: [.atomic])
        guard try Data(contentsOf: backup) == baseline else { throw SwitcherError("Mac Blue 完整备份复读不一致。") }
        try writeControlRecord(.init(backupFilename: filename, active: true, confirmed: false))
        do {
            try mutateManifest { root in root = try controlExpectedRoot(root) }
            let actual = try readManifest()
            guard (actual as NSDictionary).isEqual(to: try controlExpectedRoot(root)) else {
                throw SwitcherError("Mac Blue 控制测试写回后重读不一致；可用恢复按钮回滚。")
            }
        } catch { throw error }
        return backup.path
    }

    public func restoreManifestControlTest(observedChange: Bool = false) throws {
        guard var record = try readControlRecord() else { throw SwitcherError("没有 Mac Blue 控制测试备份。") }
        let backup = diagnosticRoot.appendingPathComponent(record.backupFilename)
        let baseline = try Data(contentsOf: backup)
        guard let original = try JSONSerialization.jsonObject(with: baseline) as? [String: Any] else {
            throw SwitcherError("Mac Blue 控制测试备份不是有效 JSON。")
        }
        let current = try readManifest()
        let expected = try controlExpectedRoot(original)
        guard (current as NSDictionary).isEqual(to: expected) || (current as NSDictionary).isEqual(to: original) else {
            throw SwitcherError("当前 manifest 除 Mac Blue 排序外还发生变化；为避免覆盖新内容，已停止自动恢复。完整备份保留在 \(backup.path)")
        }
        if try Data(contentsOf: paths.manifest) != baseline {
            let temp = paths.manifest.deletingLastPathComponent().appendingPathComponent(".dws-control-\(UUID().uuidString).json")
            defer { try? fm.removeItem(at: temp) }
            try baseline.write(to: temp)
            guard let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: temp)) as? [String: Any],
                  (parsed as NSDictionary).isEqual(to: original) else { throw SwitcherError("恢复临时文件校验失败。") }
            let before = try Data(contentsOf: paths.manifest)
            guard (try readManifest() as NSDictionary).isEqual(to: current), try Data(contentsOf: paths.manifest) == before else {
                throw SwitcherError("恢复期间 manifest 变化；已停止替换。")
            }
            guard Darwin.rename(temp.path, paths.manifest.path) == 0 else {
                throw SwitcherError("Mac Blue 备份原子恢复失败：\(String(cString: strerror(errno)))")
            }
            guard try Data(contentsOf: paths.manifest) == baseline else { throw SwitcherError("Mac Blue 备份恢复后复读不一致。") }
        }
        record.active = false
        record.confirmed = observedChange
        try writeControlRecord(record)
    }

    @discardableResult
    public func createMacBlueCloneTest(id: UUID = UUID()) throws -> String {
        guard let control = try readControlRecord(), !control.active, control.confirmed else {
            throw SwitcherError("请先确认 Mac Blue 排序确实变化，并恢复控制测试。")
        }
        if try readCloneRecord() != nil { throw SwitcherError("已有本 App 的 Mac Blue 克隆测试 asset。") }
        let assetID = id.uuidString.uppercased()
        let shotID = "CUSTOM_TEST_" + assetID.replacingOccurrences(of: "-", with: "").prefix(8)
        let root = try readManifest()
        let template = try macBlueAsset(root)
        guard !(try assetArray(root)).contains(where: { $0["id"] as? String == assetID }) else { throw SwitcherError("测试 UUID 已被占用。") }
        try fm.createDirectory(at: diagnosticRoot, withIntermediateDirectories: true)
        let blueThumbnail = thumbnailPNGURL(Self.knownMacAssetID)
        guard fm.fileExists(atPath: blueThumbnail.path) else {
            throw SwitcherError("未找到 Mac Blue 原生 PNG 缩略图；停止克隆测试。")
        }
        let thumbnailHash = try sha256(blueThumbnail)
        let cloneThumbnail = thumbnailPNGURL(assetID)
        guard !fm.fileExists(atPath: cloneThumbnail.path) else { throw SwitcherError("克隆 UUID 的缩略图已存在，拒绝覆盖。") }
        try writeCloneRecord(.init(id: assetID, shotID: shotID, thumbnailSHA256: thumbnailHash))
        let tempThumbnail = paths.thumbnails.appendingPathComponent(".dws-\(UUID().uuidString).png")
        defer { try? fm.removeItem(at: tempThumbnail) }
        try fm.copyItem(at: blueThumbnail, to: tempThumbnail)
        guard try sha256(tempThumbnail) == thumbnailHash else { throw SwitcherError("Mac Blue 缩略图复制校验失败。") }
        guard Darwin.rename(tempThumbnail.path, cloneThumbnail.path) == 0 else {
            throw SwitcherError("Mac Blue 克隆缩略图安装失败。")
        }
        try mutateManifest { root in
            var assets = try assetArray(root)
            guard !assets.contains(where: { $0["id"] as? String == assetID }) else { throw SwitcherError("测试 UUID 已被占用。") }
            var clone = template
            clone["id"] = assetID
            clone["shotID"] = shotID
            clone["preferredOrder"] = 84
            assets.append(clone)
            root["assets"] = assets
        }
        let actual = try readManifest()
        guard let clone = try assetArray(actual).first(where: { $0["id"] as? String == assetID }),
              clone["shotID"] as? String == shotID,
              clone["preferredOrder"] as? Int == 84 else { throw SwitcherError("Mac Blue 克隆写回后重读失败。") }
        return assetID
    }

    public func deleteMacBlueCloneTest() throws {
        guard let record = try readCloneRecord() else { throw SwitcherError("没有本 App 记录的 Mac Blue 克隆测试 asset。") }
        try mutateManifest { root in
            var assets = try assetArray(root)
            if let index = assets.firstIndex(where: { $0["id"] as? String == record.id }) {
                guard assets[index]["shotID"] as? String == record.shotID else { throw SwitcherError("同 UUID 的 asset 已变化；拒绝删除。") }
                assets.remove(at: index)
                root["assets"] = assets
            }
        }
        if let thumbnailHash = record.thumbnailSHA256,
           fm.fileExists(atPath: thumbnailPNGURL(record.id).path) {
            guard try sha256(thumbnailPNGURL(record.id)) == thumbnailHash else {
                throw SwitcherError("克隆缩略图已被其他内容替换；已保留文件供检查。")
            }
            try fm.removeItem(at: thumbnailPNGURL(record.id))
        }
        try fm.removeItem(at: cloneRecordURL)
    }

    private func macBlueAsset(_ root: [String: Any]) throws -> [String: Any] {
        guard let blue = try assetArray(root).first(where: { $0["id"] as? String == Self.knownMacAssetID }),
              blue["preferredOrder"] as? Int == 81,
              blue["localizedNameKey"] as? String == "MAC_WP_BLU_NAME",
              blue["categories"] as? [String] == [Self.macCategoryID],
              blue["subcategories"] as? [String] == [Self.macSubcategoryID] else {
            throw SwitcherError("Mac Blue 模板与预期不符；停止测试。")
        }
        return blue
    }

    private func controlExpectedRoot(_ original: [String: Any]) throws -> [String: Any] {
        _ = try macBlueAsset(original)
        var expected = original
        var assets = try assetArray(expected)
        guard let index = assets.firstIndex(where: { $0["id"] as? String == Self.knownMacAssetID }) else { throw SwitcherError("缺少 Mac Blue。") }
        assets[index]["preferredOrder"] = -999
        expected["assets"] = assets
        return expected
    }

    private func readControlRecord() throws -> ManifestControlRecord? {
        guard fm.fileExists(atPath: controlRecordURL.path) else { return nil }
        return try JSONDecoder().decode(ManifestControlRecord.self, from: Data(contentsOf: controlRecordURL))
    }

    private func readCloneRecord() throws -> ManifestCloneRecord? {
        guard fm.fileExists(atPath: cloneRecordURL.path) else { return nil }
        return try JSONDecoder().decode(ManifestCloneRecord.self, from: Data(contentsOf: cloneRecordURL))
    }

    private func writeControlRecord(_ record: ManifestControlRecord) throws {
        try fm.createDirectory(at: diagnosticRoot, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: controlRecordURL, options: [.atomic])
    }

    private func writeCloneRecord(_ record: ManifestCloneRecord) throws {
        try fm.createDirectory(at: diagnosticRoot, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: cloneRecordURL, options: [.atomic])
    }

    public func experimentalDiagnostics(_ id: String, processReport: String) throws -> String {
        let owned = try readOwned()
        guard let asset = owned.assets.first(where: { $0.id == id && $0.categoryID == Self.macCategoryID }) else {
            throw SwitcherError("找不到本应用拥有的实验资源。")
        }
        let live = cacheURL(id)
        let exists = fm.fileExists(atPath: live.path)
        let bytes = exists ? ((try fm.attributesOfItem(atPath: live.path)[.size] as? NSNumber)?.int64Value ?? 0) : 0
        let hash = exists ? try sha256(live) : "不存在"
        let manifest = try readManifest()
        let found = try assetArray(manifest).contains { $0["id"] as? String == id && $0["shotID"] as? String == asset.shotID }
        return """
        DynamicWallpaperSwitcher A/B 诊断
        manifest: \(paths.manifest.path)
        asset UUID: \(id)
        shotID: \(asset.shotID)
        category ID: \(Self.macCategoryID)
        subcategory ID: \(Self.macSubcategoryID)
        本地视频: \(live.path)
        本地视频存在: \(exists ? "是" : "否")
        文件大小: \(bytes) bytes
        SHA-256: \(hash)
        与 App 主副本哈希匹配: \(hash == asset.videoSHA256 ? "是" : "否")
        manifest 重读 JSON parse: 成功
        manifest 重读找到 asset: \(found ? "是" : "否")
        进程刷新: \(processReport)
        系统设置卡片与实际播放: 待人工观察
        """
    }

    @discardableResult
    public func importExperimentalMOV(_ source: URL, displayName: String? = nil, id: UUID = UUID(),
                                      progress: (String) -> Void = { _ in }) throws -> CustomAerialAsset {
        guard source.pathExtension.lowercased() == "mov" else { throw SwitcherError("实验模式只接受 MOV，以减少容器格式变量。") }
        return try importVideo(source, displayName: displayName, id: id, mode: .experimental, progress: progress)
    }

    public func list() throws -> [CustomAssetHealth] {
        let owned = try readOwned()
        let manifest = try readManifest()
        let entries = try assetArray(manifest)
        let customSub = try customSubcategory(manifest)
        return owned.assets.map { asset in
            let original = originalURL(asset.id)
            let cached = cacheURL(asset.id)
            let hasOriginal = fm.fileExists(atPath: original.path)
            let hasCache = fm.fileExists(atPath: cached.path)
            let originalValid = hasOriginal && ((try? sha256(original)) == asset.videoSHA256)
            let cacheValid = hasCache && ((try? sha256(cached)) == asset.videoSHA256)
            let present = entries.contains { entry in
                guard entry["id"] as? String == asset.id, entry["shotID"] as? String == asset.shotID else { return false }
                if asset.mode != .custom { return true }
                if asset.categoryID == Self.formalCategoryID {
                    return (entry["categories"] as? [String]) == [Self.formalCategoryID]
                        && (entry["subcategories"] as? [String]) == [Self.formalSubcategoryID]
                        && ((try? categoryArray(manifest)) ?? []).contains { $0["id"] as? String == Self.formalCategoryID }
                }
                return (entry["categories"] as? [String]) == [Self.macCategoryID]
                    && (entry["subcategories"] as? [String]) == [Self.customSubcategoryID]
                    && customSub != nil
            }
            return CustomAssetHealth(asset: asset, manifestPresent: present,
                cachePresent: hasCache, originalPresent: hasOriginal,
                thumbnailPresent: fm.fileExists(atPath: thumbnailURL(asset.id).path)
                    && (asset.mode != .legacy
                        ? fm.fileExists(atPath: thumbnailPNGURL(asset.id).path)
                        : fm.fileExists(atPath: installedThumbnailURL(asset.id).path)),
                hashMatches: originalValid && cacheValid)
        }
    }

    @discardableResult
    public func importVideo(_ source: URL, displayName: String? = nil, id: UUID = UUID(), progress: (String) -> Void = { _ in }) throws -> CustomAerialAsset {
        guard source.pathExtension.lowercased() == "mov" else { throw SwitcherError("正式导入仅接受 MOV 视频。") }
        return try importVideo(source, displayName: displayName, id: id, mode: .custom, progress: progress)
    }

    /// GUI entry point. All media checks finish before the first live manifest write.
    @discardableResult
    public func importConvertedVideo(_ movie: URL, sourceFilename: String, displayName: String,
                                     thumbnail: URL? = nil,
                                     progress: (String) -> Void = { _ in }) throws -> CustomAerialAsset {
        progress("正在复核动态壁纸兼容性…")
        _ = try AerialCompatibilityChecker().check(movie, ffmpeg: FFmpegLocator.locate())
        return try importVideo(movie, displayName: displayName, id: UUID(), mode: .custom,
                               originalSourceFilename: sourceFilename, forceFormalCategory: true,
                               thumbnailSource: thumbnail, compatibilityValidated: true, progress: progress)
    }

    private func importVideo(_ source: URL, displayName: String?, id: UUID, mode: CustomAssetMode,
                             originalSourceFilename: String? = nil, forceFormalCategory: Bool = false,
                             thumbnailSource: URL? = nil, compatibilityValidated: Bool = false,
                             progress: (String) -> Void) throws -> CustomAerialAsset {
        let details = try inspector.inspect(source)
        let name = (displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? displayName! : source.deletingPathExtension().lastPathComponent)
        let uuid = id.uuidString.uppercased()
        let owned = try readOwned()
        let manifest = try readManifest()
        let formalActive = try categoryArray(manifest).contains { $0["id"] as? String == Self.formalCategoryID }
        if mode == .custom && (formalActive || forceFormalCategory) { try ensureLocalization() }
        if mode == .experimental {
            guard !owned.assets.contains(where: { $0.mode == .experimental }) else {
                throw SwitcherError("已有一张实验壁纸。请先完成 A/B 验证或删除该实验资源。")
            }
            _ = try knownMacTemplate(manifest)
        } else if mode == .custom {
            _ = try knownMacTemplate(manifest)
        }
        guard !owned.assets.contains(where: { $0.id == uuid }),
              !((try assetArray(manifest)).contains { $0["id"] as? String == uuid }),
              !fm.fileExists(atPath: assetsRoot.appendingPathComponent(uuid).path),
              !fm.fileExists(atPath: cacheURL(uuid).path),
              !fm.fileExists(atPath: thumbnailPNGURL(uuid).path),
              !fm.fileExists(atPath: installedThumbnailURL(uuid).path) else { throw SwitcherError("UUID 已存在；没有覆盖任何内容。") }
        guard fm.fileExists(atPath: paths.videos.path) else { throw SwitcherError("未找到 Aerials 视频缓存目录。") }
        try fm.createDirectory(at: assetsRoot, withIntermediateDirectories: true)
        let assetDir = assetsRoot.appendingPathComponent(uuid)
        try fm.createDirectory(at: assetDir, withIntermediateDirectories: false)
        var committed = false
        var thumbnailInstalled = false
        var cacheInstalled = false
        defer {
            if !committed {
                if thumbnailInstalled {
                    try? fm.removeItem(at: mode == .legacy ? installedThumbnailURL(uuid) : thumbnailPNGURL(uuid))
                }
                if cacheInstalled { try? fm.removeItem(at: cacheURL(uuid)) }
                try? fm.removeItem(at: assetDir)
            }
        }
        let original = originalURL(uuid)
        progress("保存视频主副本…")
        let sourceHash = try sha256(source)
        try fm.copyItem(at: source, to: original)
        guard try sha256(original) == sourceHash else { throw SwitcherError("视频主副本校验失败。") }
        if let thumbnailSource {
            try fm.copyItem(at: thumbnailSource, to: thumbnailURL(uuid))
        } else {
            try inspector.thumbnail(original, to: thumbnailURL(uuid))
        }
        if mode != .legacy {
            try installPNGThumbnail(uuid)
            thumbnailInstalled = true
        } else {
            try installThumbnail(uuid)
            thumbnailInstalled = true
        }
        let compact = uuid.replacingOccurrences(of: "-", with: "")
        let shot = "CUSTOM_" + compact.prefix(8)
        guard !(try assetArray(manifest)).contains(where: { $0["shotID"] as? String == shot }) else {
            throw SwitcherError("shotID 已存在，停止导入。")
        }
        let asset = CustomAerialAsset(id: uuid, shotID: shot, displayName: name,
            sourceFilename: originalSourceFilename ?? source.lastPathComponent, createdAt: Date(), videoSHA256: sourceHash,
            categoryID: mode == .custom ? ((formalActive || forceFormalCategory) ? Self.formalCategoryID : Self.customSubcategoryID) : Self.macCategoryID,
            details: details, mode: mode, compatibilityValidated: compatibilityValidated)
        let assetEncoder = JSONEncoder()
        assetEncoder.dateEncodingStrategy = .iso8601
        try assetEncoder.encode(asset).write(to: assetDir.appendingPathComponent("metadata.json"), options: .atomic)
        progress("安装 Aerials 视频缓存…")
        try installCache(asset)
        cacheInstalled = true
        do {
            var next = owned
            next.assets.append(asset)
            try writeOwned(next)
            try mutateManifest { root in try upsert(asset, into: &root) }
        } catch {
            try? writeOwned(owned)
            throw error
        }
        committed = true
        return asset
    }

    public func delete(_ id: String) throws {
        var owned = try readOwned()
        guard let asset = owned.assets.first(where: { $0.id == id }) else { throw SwitcherError("该资源不属于本应用，不能删除。") }
        let remaining = owned.assets.filter { $0.id != id }
        try mutateManifest { root in
            var assets = try assetArray(root)
            guard let index = assets.firstIndex(where: { $0["id"] as? String == id }) else {
                throw SwitcherError("manifest 中已缺少该资源；请先检查或修复。")
            }
            guard assets[index]["shotID"] as? String == asset.shotID else { throw SwitcherError("manifest 中的同 ID 资源不匹配；拒绝删除。") }
            assets.remove(at: index)
            root["assets"] = assets
            if asset.mode == .custom {
                if asset.categoryID == Self.formalCategoryID {
                    try updateFormalCategory(in: &root, ownedIDs: Set(remaining.filter {
                        $0.mode == .custom && $0.categoryID == Self.formalCategoryID
                    }.map(\.id)))
                } else {
                    try updateCustomSubcategory(in: &root, ownedIDs: Set(remaining.filter {
                        $0.mode == .custom && $0.categoryID == Self.customSubcategoryID
                    }.map(\.id)))
                }
            } else if asset.mode == .legacy {
                let remainingCategoryAssets = assets.filter {
                    (($0["categories"] as? [String]) ?? []).contains(Self.categoryID)
                }
                if remainingCategoryAssets.isEmpty {
                    var categories = try categoryArray(root)
                    categories.removeAll { $0["id"] as? String == Self.categoryID }
                    root["categories"] = categories
                } else if let representative = remainingCategoryAssets.first?["id"] as? String {
                    var categories = try categoryArray(root)
                    if let index = categories.firstIndex(where: { $0["id"] as? String == Self.categoryID }) {
                        categories[index]["representativeAssetID"] = representative
                        if fm.fileExists(atPath: installedThumbnailURL(representative).path) {
                            categories[index]["previewImage"] = installedThumbnailURL(representative).absoluteString
                        }
                        root["categories"] = categories
                    }
                }
            }
        }
        if fm.fileExists(atPath: cacheURL(id).path) { try fm.removeItem(at: cacheURL(id)) }
        if fm.fileExists(atPath: installedThumbnailURL(id).path) { try fm.removeItem(at: installedThumbnailURL(id)) }
        if asset.mode != .legacy && fm.fileExists(atPath: thumbnailPNGURL(id).path) {
            try fm.removeItem(at: thumbnailPNGURL(id))
        }
        if fm.fileExists(atPath: assetDirectory(id).path) { try fm.removeItem(at: assetDirectory(id)) }
        owned.assets = remaining
        try writeOwned(owned)
    }

    public func repair(_ id: String) throws {
        let owned = try readOwned()
        guard let asset = owned.assets.first(where: { $0.id == id }) else { throw SwitcherError("该资源不属于本应用，不能修复。") }
        let original = originalURL(id)
        guard fm.fileExists(atPath: original.path) else { throw SwitcherError("主副本丢失：\(original.path)。不会删除现有 manifest 条目。") }
        guard try sha256(original) == asset.videoSHA256 else { throw SwitcherError("主副本 SHA-256 不匹配；停止修复。") }
        if !fm.fileExists(atPath: thumbnailURL(id).path) { try inspector.thumbnail(original, to: thumbnailURL(id)) }
        if asset.mode != .legacy && !fm.fileExists(atPath: thumbnailPNGURL(id).path) {
            try installPNGThumbnail(id)
        } else if asset.mode == .legacy && !fm.fileExists(atPath: installedThumbnailURL(id).path) {
            try installThumbnail(id)
        }
        let cacheValid = (try? sha256(cacheURL(id))) == asset.videoSHA256
        if !cacheValid {
            try installCache(asset, replacingOwned: true)
        }
        let manifest = try readManifest()
        let hasAsset = try assetArray(manifest).contains { $0["id"] as? String == id }
        let hasCategory: Bool
        if asset.mode == .custom {
            if asset.categoryID == Self.formalCategoryID {
                hasCategory = try categoryArray(manifest).contains { $0["id"] as? String == Self.formalCategoryID }
            } else { hasCategory = try customSubcategory(manifest) != nil }
        } else {
            hasCategory = try categoryArray(manifest).contains { $0["id"] as? String == asset.categoryID }
        }
        var representativeValid = true
        if asset.mode == .custom {
            let representative: String?
            if asset.categoryID == Self.formalCategoryID {
                representative = try categoryArray(manifest).first {
                    $0["id"] as? String == Self.formalCategoryID
                }?["representativeAssetID"] as? String
            } else { representative = try customSubcategory(manifest)?["representativeAssetID"] as? String }
            representativeValid = try assetArray(manifest).contains {
                $0["id"] as? String == representative && ($0["subcategories"] as? [String]) ==
                    [asset.categoryID == Self.formalCategoryID ? Self.formalSubcategoryID : Self.customSubcategoryID]
            }
        }
        if !hasAsset || !hasCategory || !representativeValid {
            if asset.categoryID == Self.formalCategoryID { try ensureLocalization() }
            try mutateManifest { root in try upsert(asset, into: &root) }
        }
    }

    public func repairAll() -> [String] {
        guard let owned = try? readOwned() else { return ["元数据无法读取。"] }
        return owned.assets.compactMap { asset in
            do { try repair(asset.id); return nil }
            catch { return "\(asset.displayName)：\(error.localizedDescription)" }
        }
    }

    public func migrateLegacy(_ id: String) throws {
        var owned = try readOwned()
        guard let index = owned.assets.firstIndex(where: { $0.id == id && $0.mode == .legacy }) else {
            throw SwitcherError("未找到本 App 的旧版自定义壁纸。")
        }
        let old = owned.assets[index]
        guard fm.fileExists(atPath: originalURL(id).path),
              try sha256(originalURL(id)) == old.videoSHA256 else {
            throw SwitcherError("旧版视频主副本缺失或 SHA-256 不匹配；已停止迁移。")
        }
        if !fm.fileExists(atPath: thumbnailURL(id).path) { try inspector.thumbnail(originalURL(id), to: thumbnailURL(id)) }
        if !fm.fileExists(atPath: thumbnailPNGURL(id).path) { try installPNGThumbnail(id) }
        if (try? sha256(cacheURL(id))) != old.videoSHA256 { try installCache(old, replacingOwned: true) }
        let shortShot = "CUSTOM_" + old.id.replacingOccurrences(of: "-", with: "").prefix(8)
        let updated = CustomAerialAsset(id: old.id, shotID: shortShot, displayName: old.displayName,
            sourceFilename: old.sourceFilename, createdAt: old.createdAt, videoSHA256: old.videoSHA256,
            categoryID: (try categoryArray(readManifest())).contains { $0["id"] as? String == Self.formalCategoryID }
                ? Self.formalCategoryID : Self.customSubcategoryID, details: old.details, mode: .custom)
        if updated.categoryID == Self.formalCategoryID { try ensureLocalization() }
        let previous = owned
        owned.assets[index] = updated
        try writeOwned(owned)
        do {
            try mutateManifest { root in
                var assets = try assetArray(root)
                guard let oldIndex = assets.firstIndex(where: { $0["id"] as? String == id }),
                      assets[oldIndex]["shotID"] as? String == old.shotID else {
                    throw SwitcherError("旧版 manifest 条目缺失或身份不匹配。")
                }
                assets.remove(at: oldIndex)
                root["assets"] = assets
                try upsert(updated, into: &root)
                if !(try assetArray(root)).contains(where: { (($0["categories"] as? [String]) ?? []).contains(Self.categoryID) }) {
                    var categories = try categoryArray(root)
                    if let oldIndex = categories.firstIndex(where: { $0["id"] as? String == Self.categoryID }) {
                        guard categories[oldIndex]["localizedNameKey"] as? String == "自定义" else {
                            throw SwitcherError("旧版顶层分类已变化；已停止迁移。")
                        }
                        categories.remove(at: oldIndex)
                        root["categories"] = categories
                    }
                }
            }
        } catch {
            try? writeOwned(previous)
            throw error
        }
        if fm.fileExists(atPath: installedThumbnailURL(id).path) { try fm.removeItem(at: installedThumbnailURL(id)) }
    }

    private func assetDirectory(_ id: String) -> URL { assetsRoot.appendingPathComponent(id) }
    private func originalURL(_ id: String) -> URL { assetDirectory(id).appendingPathComponent("original.mov") }
    private func thumbnailURL(_ id: String) -> URL { assetDirectory(id).appendingPathComponent("thumbnail.jpg") }
    private func installedThumbnailURL(_ id: String) -> URL { paths.thumbnails.appendingPathComponent(id + ".jpg") }
    private func thumbnailPNGURL(_ id: String) -> URL { paths.thumbnails.appendingPathComponent(id + ".png") }
    private func cacheURL(_ id: String) -> URL { paths.videos.appendingPathComponent(id + ".mov") }

    private func installThumbnail(_ id: String) throws {
        try fm.createDirectory(at: paths.thumbnails, withIntermediateDirectories: true)
        let target = installedThumbnailURL(id)
        let source = thumbnailURL(id)
        let hash = try sha256(source)
        let temp = paths.thumbnails.appendingPathComponent(".dws-\(UUID().uuidString).jpg")
        defer { try? fm.removeItem(at: temp) }
        try fm.copyItem(at: source, to: temp)
        guard try sha256(temp) == hash else { throw SwitcherError("缩略图缓存校验失败。") }
        guard Darwin.rename(temp.path, target.path) == 0 else { throw SwitcherError("无法安装缩略图缓存。") }
    }

    private func installPNGThumbnail(_ id: String) throws {
        let target = thumbnailPNGURL(id)
        guard !fm.fileExists(atPath: target.path) else { throw SwitcherError("同 UUID 的 PNG 缩略图已存在，拒绝覆盖。") }
        guard let image = NSImage(contentsOf: thumbnailURL(id)),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 356, pixelsHigh: 356,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw SwitcherError("无法读取 App 自有视频缩略图并生成 PNG。")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let side = min(image.size.width, image.size.height)
        let crop = NSRect(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2,
                          width: side, height: side)
        image.draw(in: NSRect(x: 0, y: 0, width: 356, height: 356), from: crop,
                   operation: .copy, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SwitcherError("PNG 缩略图编码失败。")
        }
        try fm.createDirectory(at: paths.thumbnails, withIntermediateDirectories: true)
        let temp = paths.thumbnails.appendingPathComponent(".dws-\(UUID().uuidString).png")
        defer { try? fm.removeItem(at: temp) }
        try data.write(to: temp)
        guard let verify = NSBitmapImageRep(data: try Data(contentsOf: temp)),
              verify.pixelsWide == 356, verify.pixelsHigh == 356 else {
            throw SwitcherError("PNG 缩略图复读校验失败。")
        }
        guard Darwin.rename(temp.path, target.path) == 0 else { throw SwitcherError("PNG 缩略图原子安装失败。") }
    }

    private func readOwned() throws -> OwnedAssets {
        guard fm.fileExists(atPath: metadataURL.path) else { return OwnedAssets() }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let result = try decoder.decode(OwnedAssets.self, from: Data(contentsOf: metadataURL))
            guard result.version == 1 else { throw SwitcherError("元数据版本不受支持。") }
            return result
        } catch { throw SwitcherError("自定义资源元数据损坏：\(error.localizedDescription)") }
    }

    private func writeOwned(_ owned: OwnedAssets) throws {
        try fm.createDirectory(at: customRoot, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(owned).write(to: metadataURL, options: .atomic)
    }

    private func readManifest() throws -> [String: Any] {
        guard fm.fileExists(atPath: paths.manifest.path) else { throw SwitcherError("未找到 Aerials entries.json：\(paths.manifest.path)") }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.manifest))
        guard let root = object as? [String: Any] else { throw SwitcherError("entries.json 顶层不是 JSON 对象。") }
        _ = try assetArray(root); _ = try categoryArray(root)
        return root
    }

    private func assetArray(_ root: [String: Any]) throws -> [[String: Any]] {
        guard let value = root["assets"] as? [[String: Any]] else { throw SwitcherError("entries.json 缺少 assets 数组。") }
        return value
    }

    private func categoryArray(_ root: [String: Any]) throws -> [[String: Any]] {
        guard let value = root["categories"] as? [[String: Any]] else { throw SwitcherError("entries.json 缺少 categories 数组。") }
        return value
    }

    private func upsert(_ asset: CustomAerialAsset, into root: inout [String: Any]) throws {
        if asset.mode == .legacy { try ensureCategory(asset, in: &root) }
        var assets = try assetArray(root)
        if let index = assets.firstIndex(where: { $0["id"] as? String == asset.id }) {
            let existing = assets[index]
            guard existing["shotID"] as? String == asset.shotID else { throw SwitcherError("manifest 资源 ID 冲突。") }
            if asset.mode == .custom {
                assets[index] = try customEntry(asset, root: root, order: (existing["preferredOrder"] as? Int) ?? 0)
                root["assets"] = assets
                if asset.categoryID == Self.formalCategoryID {
                    try updateFormalCategory(in: &root, ownedIDs: Set(try readOwned().assets.filter {
                        $0.mode == .custom && $0.categoryID == Self.formalCategoryID
                    }.map(\.id)))
                } else {
                    try updateCustomSubcategory(in: &root, ownedIDs: Set(try readOwned().assets.filter {
                        $0.mode == .custom && $0.categoryID == Self.customSubcategoryID
                    }.map(\.id)))
                }
            }
            return
        }
        if asset.mode == .custom {
            let targetSub = asset.categoryID == Self.formalCategoryID ? Self.formalSubcategoryID : Self.customSubcategoryID
            let order = assets.filter { ($0["subcategories"] as? [String]) == [targetSub] }.count
            assets.append(try customEntry(asset, root: root, order: order))
            root["assets"] = assets
            if asset.categoryID == Self.formalCategoryID {
                try updateFormalCategory(in: &root, ownedIDs: Set(try readOwned().assets.filter {
                    $0.mode == .custom && $0.categoryID == Self.formalCategoryID
                }.map(\.id)))
            } else {
                try updateCustomSubcategory(in: &root, ownedIDs: Set(try readOwned().assets.filter {
                    $0.mode == .custom && $0.categoryID == Self.customSubcategoryID
                }.map(\.id)))
            }
            return
        } else if asset.mode == .experimental {
            let template = try knownMacTemplate(root)
            assets.append([
                "id": asset.id, "shotID": asset.shotID, "accessibilityLabel": asset.displayName,
                "localizedNameKey": asset.displayName, "categories": [Self.macCategoryID],
                "subcategories": [Self.macSubcategoryID], "showInTopLevel": true,
                "includeInShuffle": false, "preferredOrder": 999,
                "pointsOfInterest": [String: String](),
                "previewImage": template.preview,
                "url-4K-SDR-240FPS": template.video
            ])
        } else {
            assets.append([
                "id": asset.id, "shotID": asset.shotID, "accessibilityLabel": asset.displayName,
                "localizedNameKey": asset.displayName, "categories": [Self.categoryID], "subcategories": [],
                "showInTopLevel": false, "includeInShuffle": false, "preferredOrder": 0,
                "pointsOfInterest": [String: String](),
                "previewImage": installedThumbnailURL(asset.id).absoluteString,
                "url-4K-SDR-240FPS": cacheURL(asset.id).absoluteString
            ])
        }
        root["assets"] = assets
    }

    private func customEntry(_ asset: CustomAerialAsset, root: [String: Any], order: Int) throws -> [String: Any] {
        let template = try knownMacTemplate(root)
        let formal = asset.categoryID == Self.formalCategoryID
        return [
            "id": asset.id, "shotID": asset.shotID, "accessibilityLabel": asset.displayName,
            "localizedNameKey": asset.displayName,
            "categories": [formal ? Self.formalCategoryID : Self.macCategoryID],
            "subcategories": [formal ? Self.formalSubcategoryID : Self.customSubcategoryID], "showInTopLevel": true,
            "includeInShuffle": false, "preferredOrder": order,
            "pointsOfInterest": [String: String](), "previewImage": template.preview,
            "url-4K-SDR-240FPS": template.video
        ]
    }

    private func customSubcategory(_ root: [String: Any]) throws -> [String: Any]? {
        guard let mac = try categoryArray(root).first(where: { $0["id"] as? String == Self.macCategoryID }),
              let subs = mac["subcategories"] as? [[String: Any]] else { throw SwitcherError("Mac 分类结构无效。") }
        return subs.first { $0["id"] as? String == Self.customSubcategoryID }
    }

    private func updateCustomSubcategory(in root: inout [String: Any], ownedIDs: Set<String>) throws {
        var categories = try categoryArray(root)
        guard let macIndex = categories.firstIndex(where: { $0["id"] as? String == Self.macCategoryID }),
              var subs = categories[macIndex]["subcategories"] as? [[String: Any]] else {
            throw SwitcherError("未找到 Mac 分类及其 subcategories。")
        }
        let assets = try assetArray(root)
        let custom = assets.filter { ($0["subcategories"] as? [String]) == [Self.customSubcategoryID] }
        guard custom.allSatisfy({ ownedIDs.contains($0["id"] as? String ?? "") }) else {
            throw SwitcherError("自定义子分类含有非本 App 管理的资源；已停止修改。")
        }
        let subIndex = subs.firstIndex { $0["id"] as? String == Self.customSubcategoryID }
        if let subIndex {
            guard subs[subIndex]["localizedNameKey"] as? String == "自定义" else {
                throw SwitcherError("自定义子分类 ID 已被其他内容占用。")
            }
        }
        if custom.isEmpty {
            if let subIndex { subs.remove(at: subIndex) }
        } else {
            let currentRep = subIndex.flatMap { subs[$0]["representativeAssetID"] as? String }
            let representative = custom.first { $0["id"] as? String == currentRep } ?? custom[0]
            let repID = representative["id"] as! String
            let preview = representative["previewImage"] as! String
            if let subIndex {
                subs[subIndex]["representativeAssetID"] = repID
                subs[subIndex]["previewImage"] = preview
            } else {
                subs.append(["id": Self.customSubcategoryID, "localizedNameKey": "自定义",
                             "localizedDescriptionKey": "自定义", "preferredOrder": 100,
                             "previewImage": preview, "representativeAssetID": repID])
            }
        }
        categories[macIndex]["subcategories"] = subs
        root["categories"] = categories
    }

    private func updateFormalCategory(in root: inout [String: Any], ownedIDs: Set<String>) throws {
        var categories = try categoryArray(root)
        let assets = try assetArray(root)
        let custom = assets.filter {
            ($0["categories"] as? [String]) == [Self.formalCategoryID]
                && ($0["subcategories"] as? [String]) == [Self.formalSubcategoryID]
        }
        guard custom.allSatisfy({ ownedIDs.contains($0["id"] as? String ?? "") }) else {
            throw SwitcherError("独立自定义分类包含非本 App 资源，停止修改。")
        }
        let index = categories.firstIndex { $0["id"] as? String == Self.formalCategoryID }
        if let index {
            guard categories[index]["localizedNameKey"] as? String == AerialLocalization.nameKey else {
                throw SwitcherError("独立自定义分类 ID 已被其他内容占用。")
            }
        }
        if custom.isEmpty {
            if let index { categories.remove(at: index) }
        } else {
            let currentRep = index.flatMap { categories[$0]["representativeAssetID"] as? String }
            let representative = custom.first { $0["id"] as? String == currentRep } ?? custom[0]
            let repID = representative["id"] as! String
            let mac = categories.first { $0["id"] as? String == Self.macCategoryID }
            let preferred = mac?["preferredOrder"] as? Int ?? 0
            let sub: [String: Any] = [
                "id": Self.formalSubcategoryID,
                "localizedNameKey": AerialLocalization.nameKey,
                "localizedDescriptionKey": AerialLocalization.descriptionKey,
                "preferredOrder": 0,
                "previewImage": representative["previewImage"] as? String ?? "",
                "representativeAssetID": repID
            ]
            if let index {
                categories[index]["representativeAssetID"] = repID
                categories[index]["previewImage"] = mac?["previewImage"] as? String ?? representative["previewImage"]
                categories[index]["subcategories"] = [sub]
            } else {
                categories.append([
                    "id": Self.formalCategoryID,
                    "localizedNameKey": AerialLocalization.nameKey,
                    "localizedDescriptionKey": AerialLocalization.descriptionKey,
                    "preferredOrder": preferred,
                    "previewImage": mac?["previewImage"] as? String ?? representative["previewImage"] as? String ?? "",
                    "representativeAssetID": repID,
                    "subcategories": [sub]
                ])
            }
        }
        root["categories"] = categories
    }

    private func knownMacTemplate(_ root: [String: Any]) throws -> (preview: String, video: String) {
        let categories = try categoryArray(root)
        guard let mac = categories.first(where: { $0["id"] as? String == Self.macCategoryID }),
              let subcategories = mac["subcategories"] as? [[String: Any]],
              subcategories.contains(where: { $0["id"] as? String == Self.macSubcategoryID }),
              let apple = try assetArray(root).first(where: { $0["id"] as? String == Self.knownMacAssetID }),
              let preview = apple["previewImage"] as? String,
              let video = apple["url-4K-SDR-240FPS"] as? String,
              URL(string: preview)?.scheme == "https", URL(string: video)?.scheme == "https" else {
            throw SwitcherError("未找到已验证的 Mac 分类和 Apple HTTPS 素材模板；停止实验导入。")
        }
        return (preview, video)
    }

    private func ensureCategory(_ asset: CustomAerialAsset, in root: inout [String: Any]) throws {
        var categories = try categoryArray(root)
        if let index = categories.firstIndex(where: { $0["id"] as? String == Self.categoryID }) {
            guard categories[index]["localizedNameKey"] as? String == "自定义" else { throw SwitcherError("自定义分类 ID 已被其他内容占用。") }
            if categories[index]["representativeAssetID"] as? String != asset.id {
                categories[index]["representativeAssetID"] = asset.id
                categories[index]["previewImage"] = installedThumbnailURL(asset.id).absoluteString
                root["categories"] = categories
            }
            return
        }
        let preferred = ((categories.compactMap { $0["preferredOrder"] as? Int }).max() ?? 0) + 1
        categories.append([
            "id": Self.categoryID, "localizedNameKey": "自定义", "localizedDescriptionKey": "自定义视频",
            "preferredOrder": preferred, "previewImage": installedThumbnailURL(asset.id).absoluteString,
            "representativeAssetID": asset.id, "subcategories": []
        ])
        root["categories"] = categories
    }

    private func mutateManifest(_ change: (inout [String: Any]) throws -> Void) throws {
        let baseline = try Data(contentsOf: paths.manifest)
        guard var root = try JSONSerialization.jsonObject(with: baseline) as? [String: Any] else {
            throw SwitcherError("entries.json 顶层不是 JSON 对象。")
        }
        _ = try assetArray(root); _ = try categoryArray(root)
        try change(&root)
        let encoded = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
        try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let backup = backupRoot.appendingPathComponent("entries-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).json")
        try fm.copyItem(at: paths.manifest, to: backup)
        guard try Data(contentsOf: backup) == baseline else { throw SwitcherError("manifest 在备份期间变化；已停止写入。") }
        let temp = paths.manifest.deletingLastPathComponent().appendingPathComponent(".dws-\(UUID().uuidString).json")
        defer { try? fm.removeItem(at: temp) }
        try encoded.write(to: temp)
        let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: temp))
        guard let verified = decoded as? [String: Any] else { throw SwitcherError("临时 manifest 无效。") }
        _ = try assetArray(verified); _ = try categoryArray(verified)
        guard (verified as NSDictionary).isEqual(to: root) else { throw SwitcherError("临时 manifest 复读不一致。") }
        try beforeManifestCommit?()
        guard try Data(contentsOf: paths.manifest) == baseline else { throw SwitcherError("manifest 在写入期间变化；已停止替换。") }
        guard Darwin.rename(temp.path, paths.manifest.path) == 0 else {
            throw SwitcherError("manifest 原子替换失败：\(String(cString: strerror(errno)))")
        }
        guard try Data(contentsOf: paths.manifest) == encoded else {
            throw SwitcherError("manifest 替换后复读不一致；备份保留在 \(backup.path)")
        }
        let backups = ((try? fm.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil)) ?? [])
            .filter { url in
                // Keep independent recovery snapshots such as entries-before-x265-poc-*.json.
                // Only rotate the timestamped snapshots created by mutateManifest.
                let name = url.deletingPathExtension().lastPathComponent
                let parts = name.split(separator: "-", maxSplits: 2)
                return parts.count == 3 && parts[0] == "entries" && Int(parts[1]) != nil
                    && url.pathExtension == "json"
            }
            .sorted { lhs, rhs in
                let left = Int(lhs.deletingPathExtension().lastPathComponent.split(separator: "-", maxSplits: 2)[1]) ?? 0
                let right = Int(rhs.deletingPathExtension().lastPathComponent.split(separator: "-", maxSplits: 2)[1]) ?? 0
                return left == right ? lhs.lastPathComponent < rhs.lastPathComponent : left < right
            }
        for old in backups.prefix(max(0, backups.count - 10)) { try? fm.removeItem(at: old) }
    }

    private func installCache(_ asset: CustomAerialAsset, replacingOwned: Bool = false) throws {
        let target = cacheURL(asset.id)
        if fm.fileExists(atPath: target.path) && !replacingOwned { throw SwitcherError("同 UUID 缓存已存在。") }
        let temp = paths.videos.appendingPathComponent(".dws-custom-\(UUID().uuidString).mov")
        defer { try? fm.removeItem(at: temp) }
        try fm.copyItem(at: originalURL(asset.id), to: temp)
        guard try sha256(temp) == asset.videoSHA256 else { throw SwitcherError("Aerials 缓存校验失败。") }
        guard Darwin.rename(temp.path, target.path) == 0 else {
            throw SwitcherError("Aerials 缓存原子安装失败：\(String(cString: strerror(errno)))")
        }
    }

    private func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty { sha.update(data: chunk) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
