import CryptoKit
import Darwin
import Foundation

public struct AerialLocalizationStatus {
    public let keysPresent: Bool
    public let categoryPresent: Bool
    public let needsRepair: Bool
    public let backupPath: String?
}

private struct LocalFileRecord: Codable, Equatable {
    let sha256: String
    let mode: UInt16
    let modificationTime: TimeInterval
}

private struct LocalizationRecord: Codable {
    let backupPath: String
    let originalFiles: [String: LocalFileRecord]
    let originalTableSHA256: String
    let patchedTableSHA256: String
    let keysAdded: [String]
}

public struct AerialLocalization {
    public static let nameKey = "DWS_Custom_Category_Name"
    public static let descriptionKey = "DWS_Custom_Category_Description"
    private let paths: AerialPaths
    private let allowTemporaryFixture: Bool
    private let fm = FileManager.default
    private var bundle: URL { paths.manifest.deletingLastPathComponent().appendingPathComponent("TVIdleScreenStrings.bundle") }
    private var table: URL { bundle.appendingPathComponent("Contents/Resources/Localizable.nocache.loctable") }
    private var state: URL { paths.support.appendingPathComponent("Localization/patch.json") }

    public init(paths: AerialPaths = .userDefault) {
        self.paths = paths; self.allowTemporaryFixture = false
    }

    init(paths: AerialPaths, allowTemporaryFixture: Bool) {
        self.paths = paths; self.allowTemporaryFixture = allowTemporaryFixture
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func digest(_ url: URL) throws -> String { digest(try Data(contentsOf: url)) }

    private func fileRecords(_ root: URL) throws -> [String: LocalFileRecord] {
        var records: [String: LocalFileRecord] = [:]
        for relative in try fm.subpathsOfDirectory(atPath: root.path) {
            if URL(fileURLWithPath: relative).lastPathComponent.hasPrefix(".dws-loc-") { continue }
            let url = root.appendingPathComponent(relative)
            let attrs = try fm.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular else { continue }
            records[relative] = LocalFileRecord(sha256: try digest(url),
                mode: (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0,
                modificationTime: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        }
        return records
    }

    private func dictionary(_ data: Data) throws -> [String: Any] {
        guard let root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              root["en"] is [String: String], root["zh_CN"] is [String: String] else {
            throw SwitcherError("本地化表结构已变化；没有写入。")
        }
        return root
    }

    private func locales(_ root: [String: Any]) -> [String] {
        root.compactMap { $0.value is [String: String] && $0.key != "LocProvenance" ? $0.key : nil }
    }

    private func record() throws -> LocalizationRecord? {
        guard fm.fileExists(atPath: state.path) else { return nil }
        return try JSONDecoder().decode(LocalizationRecord.self, from: Data(contentsOf: state))
    }

    public func status() throws -> AerialLocalizationStatus {
        let root = try dictionary(Data(contentsOf: table))
        let present = locales(root).allSatisfy { key in
            guard let terms = root[key] as? [String: String] else { return false }
            return terms[Self.nameKey] != nil && terms[Self.descriptionKey] != nil
        }
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.manifest)) as? [String: Any]
        let categories = manifest?["categories"] as? [[String: Any]] ?? []
        let category = categories.contains { $0["id"] as? String == CustomAerialManager.formalCategoryID }
        return AerialLocalizationStatus(keysPresent: present, categoryPresent: category,
                                        needsRepair: category && !present, backupPath: try record()?.backupPath)
    }

    public func ensure() throws {
        guard (bundle.path.hasPrefix(fm.homeDirectoryForCurrentUser.path + "/Library/") ||
               (allowTemporaryFixture && bundle.path.hasPrefix(fm.temporaryDirectory.path))),
              !bundle.path.hasPrefix("/System/"), fm.fileExists(atPath: table.path) else {
            throw SwitcherError("本地化资源不在当前用户 Aerials 目录，已停止。")
        }
        let baseline = try Data(contentsOf: table)
        var root = try dictionary(baseline)
        let languages = locales(root)
        guard languages.count >= 2 else { throw SwitcherError("本地化表语言结构异常。") }
        let existing = try record()
        if languages.allSatisfy({ (root[$0] as? [String: String])?[Self.nameKey] != nil &&
                                 (root[$0] as? [String: String])?[Self.descriptionKey] != nil }) {
            if existing?.patchedTableSHA256 == digest(baseline) { return }
            throw SwitcherError("发现非当前 App 记录的同名本地化键；没有覆盖。")
        }
        if languages.contains(where: { (root[$0] as? [String: String])?[Self.nameKey] != nil ||
                                       (root[$0] as? [String: String])?[Self.descriptionKey] != nil }) {
            throw SwitcherError("本地化键只存在于部分语言；请先检查，不自动覆盖。")
        }
        let originalFiles = try fileRecords(bundle)
        let backupRoot = paths.support.appendingPathComponent("Backups/Localization")
        try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let backup = backupRoot.appendingPathComponent("TVIdleScreenStrings-\(UUID().uuidString).bundle")
        try fm.copyItem(at: bundle, to: backup)
        guard try fileRecords(backup) == originalFiles else {
            throw SwitcherError("本地化 bundle 完整备份的哈希、权限或修改时间不一致。")
        }
        for language in languages {
            var terms = root[language] as! [String: String]
            terms[Self.nameKey] = language == "zh_CN" ? "自定义" : "Custom"
            terms[Self.descriptionKey] = language == "zh_CN" ? "自定义动态壁纸" : "Custom Dynamic Wallpapers"
            root[language] = terms
        }
        let patched = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        guard (try dictionary(patched) as NSDictionary).isEqual(to: root) else {
            throw SwitcherError("本地化表序列化后复读不一致。")
        }
        let temp = table.deletingLastPathComponent().appendingPathComponent(".dws-loc-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        try patched.write(to: temp)
        guard (try dictionary(Data(contentsOf: temp)) as NSDictionary).isEqual(to: root),
              try Data(contentsOf: table) == baseline else {
            throw SwitcherError("本地化表写入前发生并发改动或临时文件复读失败。")
        }
        let tableRelative = "Contents/Resources/Localizable.nocache.loctable"
        let mode = originalFiles[tableRelative]?.mode ?? 0o644
        guard Darwin.rename(temp.path, table.path) == 0 else {
            throw SwitcherError("本地化表原子替换失败。")
        }
        try fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: table.path)
        guard try digest(table) == digest(patched) else { throw SwitcherError("本地化表安装校验失败。") }
        let next = LocalizationRecord(backupPath: backup.path, originalFiles: originalFiles,
            originalTableSHA256: digest(baseline), patchedTableSHA256: digest(patched),
            keysAdded: [Self.nameKey, Self.descriptionKey])
        try fm.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: state, options: .atomic)
    }

    public func restore() throws {
        guard !(try status().categoryPresent) else {
            throw SwitcherError("自定义顶层分类仍在使用这些名称键；请先删除该分类中的所有 App 资源。")
        }
        guard let record = try record() else { throw SwitcherError("没有 App 本地化备份记录。") }
        let backup = URL(fileURLWithPath: record.backupPath)
        guard try fileRecords(backup) == record.originalFiles else {
            throw SwitcherError("完整 bundle 备份已变化，停止恢复。")
        }
        let current = try Data(contentsOf: table)
        let original = try Data(contentsOf: backup.appendingPathComponent("Contents/Resources/Localizable.nocache.loctable"))
        guard digest(original) == record.originalTableSHA256 else { throw SwitcherError("原始本地化表哈希不一致。") }
        if digest(current) != record.patchedTableSHA256 {
            var stripped = try dictionary(current)
            for language in locales(stripped) {
                var terms = stripped[language] as! [String: String]
                terms.removeValue(forKey: Self.nameKey)
                terms.removeValue(forKey: Self.descriptionKey)
                stripped[language] = terms
            }
            guard (stripped as NSDictionary).isEqual(to: try dictionary(original)) else {
                throw SwitcherError("当前 bundle 还有外部修改，停止自动恢复。")
            }
        }
        let temp = table.deletingLastPathComponent().appendingPathComponent(".dws-loc-restore-\(UUID().uuidString)")
        do {
            try original.write(to: temp)
            _ = try dictionary(Data(contentsOf: temp))
            guard try Data(contentsOf: table) == current, Darwin.rename(temp.path, table.path) == 0 else {
                throw SwitcherError("恢复前发生并发修改或原子替换失败。")
            }
        } catch {
            if fm.fileExists(atPath: temp.path) { try? fm.removeItem(at: temp) }
            throw error
        }
        guard let file = record.originalFiles["Contents/Resources/Localizable.nocache.loctable"] else {
            throw SwitcherError("备份元数据缺少本地化表，停止恢复。")
        }
        try fm.setAttributes([.posixPermissions: NSNumber(value: file.mode),
                              .modificationDate: Date(timeIntervalSince1970: file.modificationTime)],
                             ofItemAtPath: table.path)
        for (relative, expected) in record.originalFiles {
            let url = bundle.appendingPathComponent(relative)
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let actual = LocalFileRecord(sha256: try digest(url),
                mode: (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0,
                modificationTime: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
            guard actual.sha256 == expected.sha256, actual.mode == expected.mode,
                  abs(actual.modificationTime - expected.modificationTime) < 0.001 else {
                throw SwitcherError("恢复后文件与完整备份不一致：\(relative)，预期=\(expected)，实际=\(actual)")
            }
        }
        try fm.removeItem(at: state)
    }
}
