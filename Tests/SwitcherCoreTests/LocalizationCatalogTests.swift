import Foundation
import XCTest

final class LocalizationCatalogTests: XCTestCase {
    func testEnglishAndSimplifiedChineseCatalog() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalog = project.appendingPathComponent("Localizable.xcstrings")
        let data = try Data(contentsOf: catalog)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: [String: Any]])

        for (key, entry) in strings {
            let locales = try XCTUnwrap(entry["localizations"] as? [String: [String: Any]], key)
            for language in ["en", "zh-Hans"] {
                let locale = try XCTUnwrap(locales[language], "\(key): \(language)")
                let unit = try XCTUnwrap(locale["stringUnit"] as? [String: String], key)
                XCTAssertFalse((unit["value"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty, "\(key): \(language)")
            }
        }
        for key in ["自定义动态壁纸", "+ 添加视频", "Apple 墙纸工具", "使用 Tahoe 墙纸",
                    "使用 Golden Gate 墙纸", "取消", "删除", "ffmpeg 未找到", "x265 未找到",
                    "缺少 ffmpeg、ffprobe 或 x265。请安装依赖后重试；转换没有开始。",
                    "MOV 不是可读取的 hvc1 HEVC 视频", "系统墙纸资源已更新，需要修复自定义分类名称。"] {
            XCTAssertNotNil(strings[key], key)
        }
    }
}
