import CryptoKit
import Foundation
import Darwin

public enum WallpaperFile: String, CaseIterable {
    case lightLandscape = "Tahoe Light Landscape.mov"
    case darkLandscape = "Tahoe Dark Landscape.mov"
    case lightPortrait = "Tahoe Light Portrait.mov"
    case darkPortrait = "Tahoe Dark Portrait.mov"

    public var aerialID: String? {
        switch self {
        case .lightLandscape: "4DFE24ED-71CC-42D4-9FE8-3B8959B6CC19"
        case .darkLandscape: "C6AECFD2-A365-4504-9E2C-F86343F9421F"
        case .lightPortrait, .darkPortrait: nil
        }
    }

    var goldenName: String {
        switch self {
        case .lightLandscape: "Light Landscape.mov"
        case .darkLandscape: "Dark Landscape.mov"
        case .lightPortrait: "Light Portrait.mov"
        case .darkPortrait: "Dark Portrait.mov"
        }
    }
}

public enum WallpaperState: String {
    case tahoe, goldenGate, unknown
}

public struct SwitcherPaths {
    public let videos: URL
    public let support: URL
    public let aerials: URL

    public init(videos: URL, support: URL, aerials: URL) {
        self.videos = videos
        self.support = support
        self.aerials = aerials
    }

    public static var userDefault: SwitcherPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return .init(
            videos: home.appendingPathComponent("Library/Containers/com.apple.NeptuneOneExtension/Data/Library/Application Support/Videos"),
            support: home.appendingPathComponent("Library/Application Support/DynamicWallpaperSwitcher"),
            aerials: home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/videos")
        )
    }
}

public struct WallpaperSwitcher {
    public let paths: SwitcherPaths
    private let trustedTahoeHashes: [WallpaperFile: String]
    private let fm = FileManager.default

    public static let originalTahoeHashes: [WallpaperFile: String] = [
        .lightLandscape: "adb7939efe8bf632c678f9bf9b54febe6e37b7351df37bba058a665b3c7c9d7a",
        .darkLandscape: "16ecd57ff0ec1fd9a0eb8c0d8864c0c4a41bdd053ab744e25b78b3ee63f48b28",
        .lightPortrait: "8091f482b562518b9189092506bb5bb4b156916313591d29cf4c76e05f3c311d",
        .darkPortrait: "20c92d2902a2983f5471684df6584d80fda83be67bd6c7de951cb032ac46f1fd"
    ]

    public init(paths: SwitcherPaths = .userDefault, trustedTahoeHashes: [WallpaperFile: String] = WallpaperSwitcher.originalTahoeHashes) {
        self.paths = paths
        self.trustedTahoeHashes = trustedTahoeHashes
    }

    private var tahoeDir: URL { paths.support.appendingPathComponent("Tahoe") }
    private var goldenDir: URL { paths.support.appendingPathComponent("GoldenGate") }
    private var manifestURL: URL { tahoeDir.appendingPathComponent("backup-sha256.json") }

    public func prepare(progress: (String) -> Void = { _ in }) throws {
        let pending = pendingTransactions()
        guard pending.isEmpty else { throw SwitcherError("发现上次中断的切换：\(pending.map(\.lastPathComponent).joined(separator: "、"))。请先使用恢复操作。") }
        guard fm.fileExists(atPath: paths.videos.path) else {
            throw SwitcherError("未找到 Neptune 视频目录：\(paths.videos.path)")
        }
        if fm.fileExists(atPath: manifestURL.path) {
            try validateBackup()
            return
        }
        guard !fm.fileExists(atPath: tahoeDir.path) else {
            throw SwitcherError("发现未完成的 Tahoe 备份。请检查 \(tahoeDir.path)，应用不会覆盖它。")
        }
        if let light = goldenSource(.lightLandscape), let dark = goldenSource(.darkLandscape),
           try digest(light) == digest(paths.videos.appendingPathComponent(WallpaperFile.lightLandscape.rawValue)),
           try digest(dark) == digest(paths.videos.appendingPathComponent(WallpaperFile.darkLandscape.rawValue)) {
            throw SwitcherError("当前视频已是 Golden Gate，但没有 Tahoe 备份；无法把它误存为 Tahoe。")
        }
        try fm.createDirectory(at: paths.support, withIntermediateDirectories: true)
        let staging = paths.support.appendingPathComponent(".Tahoe-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        var manifest: [String: String] = [:]
        for file in WallpaperFile.allCases {
            progress("备份 \(file.rawValue)…")
            let source = paths.videos.appendingPathComponent(file.rawValue)
            let target = staging.appendingPathComponent(file.rawValue)
            let hash = try digest(source)
            guard hash == trustedTahoeHashes[file] else {
                throw SwitcherError("当前文件不符合原版 Tahoe SHA-256：\(file.rawValue)。未建立备份。")
            }
            try fm.copyItem(at: source, to: target)
            guard try digest(target) == hash else { throw SwitcherError("备份校验失败：\(file.rawValue)") }
            manifest[file.rawValue] = hash
        }
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: staging.appendingPathComponent("backup-sha256.json"))
        try fm.moveItem(at: staging, to: tahoeDir)
    }

    public func status() throws -> WallpaperState {
        try validateBackup()
        let light = paths.videos.appendingPathComponent(WallpaperFile.lightLandscape.rawValue)
        let dark = paths.videos.appendingPathComponent(WallpaperFile.darkLandscape.rawValue)
        let current = try [digest(light), digest(dark)]
        let tahoe = try [digest(tahoeDir.appendingPathComponent(WallpaperFile.lightLandscape.rawValue)),
                         digest(tahoeDir.appendingPathComponent(WallpaperFile.darkLandscape.rawValue))]
        if current == tahoe { return .tahoe }
        if let ggLight = goldenSource(.lightLandscape), let ggDark = goldenSource(.darkLandscape),
           current == (try [digest(ggLight), digest(ggDark)]) { return .goldenGate }
        return .unknown
    }

    public func switchTo(_ state: WallpaperState, progress: (String) -> Void = { _ in }) throws {
        guard state != .unknown else { throw SwitcherError("不能切换到未知状态。") }
        try prepare(progress: progress)
        let sources: [(WallpaperFile, URL)]
        if state == .tahoe {
            sources = WallpaperFile.allCases.map { ($0, tahoeDir.appendingPathComponent($0.rawValue)) }
        } else {
            guard let light = goldenSource(.lightLandscape), let dark = goldenSource(.darkLandscape) else {
                throw SwitcherError("缺少 Golden Gate 横屏视频。请先下载两段指定的 Aerials 视频。")
            }
            let importedLight = try importGolden(light, as: .lightLandscape, progress: progress)
            let importedDark = try importGolden(dark, as: .darkLandscape, progress: progress)
            var selected: [(WallpaperFile, URL)] = [(.lightLandscape, importedLight), (.darkLandscape, importedDark)]
            let pLight = goldenDir.appendingPathComponent(WallpaperFile.lightPortrait.goldenName)
            let pDark = goldenDir.appendingPathComponent(WallpaperFile.darkPortrait.goldenName)
            if fm.fileExists(atPath: pLight.path) && fm.fileExists(atPath: pDark.path) {
                selected += [(.lightPortrait, pLight), (.darkPortrait, pDark)]
            }
            sources = selected
        }
        try replace(sources, progress: progress)
    }

    public func hasGoldenPortraitPair() -> Bool {
        fm.fileExists(atPath: goldenDir.appendingPathComponent(WallpaperFile.lightPortrait.goldenName).path)
        && fm.fileExists(atPath: goldenDir.appendingPathComponent(WallpaperFile.darkPortrait.goldenName).path)
    }

    public func reset(progress: (String) -> Void = { _ in }) throws {
        try switchTo(.tahoe, progress: progress)
        for file in [WallpaperFile.lightLandscape, .darkLandscape] {
            let cached = goldenDir.appendingPathComponent(file.goldenName)
            if fm.fileExists(atPath: cached.path) { try fm.removeItem(at: cached) }
        }
    }

    private func goldenSource(_ file: WallpaperFile) -> URL? {
        let owned = goldenDir.appendingPathComponent(file.goldenName)
        if fm.fileExists(atPath: owned.path),
           let hashes = try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: goldenDir.appendingPathComponent("sha256.json"))),
           let expected = hashes[file.goldenName],
           let actual = try? digest(owned), actual == expected { return owned }
        guard let id = file.aerialID else { return nil }
        let aerial = paths.aerials.appendingPathComponent(id + ".mov")
        return fm.fileExists(atPath: aerial.path) ? aerial : nil
    }

    private func importGolden(_ source: URL, as file: WallpaperFile, progress: (String) -> Void) throws -> URL {
        let target = goldenDir.appendingPathComponent(file.goldenName)
        if source == target { return target }
        try fm.createDirectory(at: goldenDir, withIntermediateDirectories: true)
        progress("保存 Golden Gate \(file.goldenName)…")
        let hash = try digest(source)
        let temp = goldenDir.appendingPathComponent(".\(UUID().uuidString).mov")
        defer { try? fm.removeItem(at: temp) }
        try fm.copyItem(at: source, to: temp)
        guard try digest(temp) == hash else { throw SwitcherError("Golden Gate 导入校验失败。") }
        try renameReplacing(temp, target)
        let hashURL = goldenDir.appendingPathComponent("sha256.json")
        var hashes = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: hashURL))) ?? [:]
        hashes[file.goldenName] = hash
        try JSONEncoder().encode(hashes).write(to: hashURL, options: .atomic)
        return target
    }

    public func pendingTransactions() -> [URL] {
        let a = ((try? fm.contentsOfDirectory(at: paths.support, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix(".transaction-") }
        let b = ((try? fm.contentsOfDirectory(at: paths.videos, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix(".dws-") }
        return a + b
    }

    public func recoverInterrupted() throws {
        let transactions = pendingTransactions().filter { $0.lastPathComponent.hasPrefix(".transaction-") }
        for transaction in transactions {
            let manifest = transaction.appendingPathComponent("preimage-sha256.json")
            guard fm.fileExists(atPath: manifest.path) else {
                throw SwitcherError("事务缺少恢复清单，请手动检查：\(transaction.path)")
            }
            let hashes = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifest))
            for (name, expected) in hashes {
                let source = transaction.appendingPathComponent(name)
                guard try digest(source) == expected else { throw SwitcherError("恢复副本校验失败：\(source.path)") }
                let staged = paths.videos.appendingPathComponent(".dws-restore-\(UUID().uuidString).mov")
                try fm.copyItem(at: source, to: staged)
                guard try digest(staged) == expected else { throw SwitcherError("恢复临时文件校验失败：\(name)") }
                try renameReplacing(staged, paths.videos.appendingPathComponent(name))
            }
            try fm.removeItem(at: transaction)
        }
        for staging in pendingTransactions().filter({ $0.lastPathComponent.hasPrefix(".dws-") }) {
            try fm.removeItem(at: staging)
        }
    }

    private func validateBackup() throws {
        guard fm.fileExists(atPath: manifestURL.path) else { throw SwitcherError("Tahoe 备份不存在。") }
        let manifest = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifestURL))
        for file in WallpaperFile.allCases {
            guard let expected = manifest[file.rawValue],
                  expected == trustedTahoeHashes[file],
                  try digest(tahoeDir.appendingPathComponent(file.rawValue)) == expected else {
                throw SwitcherError("Tahoe 备份损坏或不完整：\(file.rawValue)")
            }
        }
    }

    private func replace(_ sources: [(WallpaperFile, URL)], progress: (String) -> Void) throws {
        let transaction = paths.support.appendingPathComponent(".transaction-\(UUID().uuidString)")
        let staging = paths.videos.appendingPathComponent(".dws-\(UUID().uuidString)")
        try fm.createDirectory(at: transaction, withIntermediateDirectories: true)
        var preserveTransaction = false
        defer { if !preserveTransaction { try? fm.removeItem(at: transaction) } }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var expected: [WallpaperFile: String] = [:]
        var preimages: [String: String] = [:]
        for (file, source) in sources {
            progress("校验并准备 \(file.rawValue)…")
            let hash = try digest(source)
            let staged = staging.appendingPathComponent(file.rawValue)
            try fm.copyItem(at: source, to: staged)
            guard try digest(staged) == hash else { throw SwitcherError("临时副本校验失败：\(file.rawValue)") }
            let live = paths.videos.appendingPathComponent(file.rawValue)
            let old = transaction.appendingPathComponent(file.rawValue)
            let oldHash = try digest(live)
            try fm.copyItem(at: live, to: old)
            guard try digest(old) == oldHash else { throw SwitcherError("原视频安全副本校验失败：\(file.rawValue)") }
            expected[file] = hash
            preimages[file.rawValue] = oldHash
        }
        try JSONEncoder().encode(preimages).write(to: transaction.appendingPathComponent("preimage-sha256.json"), options: .atomic)
        var changed: [WallpaperFile] = []
        do {
            for (file, _) in sources {
                progress("切换 \(file.rawValue)…")
                try renameReplacing(staging.appendingPathComponent(file.rawValue), paths.videos.appendingPathComponent(file.rawValue))
                changed.append(file)
                guard try digest(paths.videos.appendingPathComponent(file.rawValue)) == expected[file] else {
                    throw SwitcherError("替换后校验失败：\(file.rawValue)")
                }
            }
        } catch {
            var rollbackErrors: [String] = []
            for file in changed.reversed() {
                do {
                    let old = transaction.appendingPathComponent(file.rawValue)
                    let restored = staging.appendingPathComponent("restore-\(file.rawValue)")
                    try fm.copyItem(at: old, to: restored)
                    try renameReplacing(restored, paths.videos.appendingPathComponent(file.rawValue))
                } catch { rollbackErrors.append(file.rawValue) }
            }
            if rollbackErrors.isEmpty { throw error }
            preserveTransaction = true
            throw SwitcherError("切换失败，且回滚未完成：\(rollbackErrors.joined(separator: "、"))。原视频副本保留在 \(transaction.path)")
        }
    }

    private func digest(_ url: URL) throws -> String {
        guard fm.fileExists(atPath: url.path) else { throw SwitcherError("文件不存在：\(url.path)") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 12) ?? Data()
        guard header.count == 12, String(data: header[4..<8], encoding: .ascii) == "ftyp" else {
            throw SwitcherError("不是有效的 MOV 文件：\(url.lastPathComponent)")
        }
        try handle.seek(toOffset: 0)
        var sha = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty { sha.update(data: chunk) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func renameReplacing(_ source: URL, _ target: URL) throws {
        guard Darwin.rename(source.path, target.path) == 0 else {
            throw SwitcherError("无法原子替换 \(target.lastPathComponent)：\(String(cString: strerror(errno)))")
        }
    }
}

public struct SwitcherError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
