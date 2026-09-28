import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class CustomAerialsViewModel: ObservableObject {
    @Published var items: [CustomAssetHealth] = []
    @Published var busy = false
    @Published var status = ""
    @Published var error: String?
    @Published var candidateURL: URL?
    @Published var candidateDetails: VideoDetails?
    @Published var pingPong = false
    var candidateWarning: Bool {
        guard let duration = candidateDetails?.duration else { return false }
        return duration * (pingPong ? 2 : 1) > 240
    }
    @Published var quality: QualityPreset = .standard
    @Published var conversionProgress: ConversionProgress?
    @Published var dependencies = AerialVideoConverter.dependencies()
    @Published var canCancel = false
    private var cancellation: ConversionCancellation?
    @Published var diagnosticText = ""
    @Published var manifestStatus: ManifestDiagnosticStatus?
    @Published var localizationStatus: AerialLocalizationStatus?

    init() { refresh() }

    func refresh() {
        dependencies = AerialVideoConverter.dependencies()
        Task.detached {
            do {
                let manager = CustomAerialManager()
                let items = try manager.list()
                let experimental = items.first { $0.asset.mode == .experimental }
                let diagnosis = experimental.flatMap {
                    try? manager.experimentalDiagnostics($0.id, processReport: "本次打开 App 未执行进程刷新；当前：" + Self.processSnapshot())
                }
                let manifestStatus = try manager.manifestDiagnosticStatus()
                let localizationStatus = try? manager.localizationStatus()
                let controlDetails = "Manifest 两阶段诊断\nmanifest: \(manager.paths.manifest.path)\n控制测试备份: \(manifestStatus.backupPath ?? "无")\n控制测试进行中: \(manifestStatus.controlActive ? "是" : "否")\n排序变化已确认: \(manifestStatus.controlConfirmed ? "是" : "否")\n克隆 UUID: \(manifestStatus.cloneID ?? "无")"
                await MainActor.run {
                    self.items = items
                    self.diagnosticText = controlDetails + (diagnosis.map { "\n\n" + $0 } ?? "")
                    self.manifestStatus = manifestStatus
                    self.localizationStatus = localizationStatus
                    self.error = nil
                }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }

    func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.quickTimeMovie, .mpeg4Movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "选择视频"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            self.busy = true
            self.error = nil
            self.status = "正在读取视频信息…"
            Task.detached {
                do {
                    let details = try CustomAerialManager().inspect(url)
                    await MainActor.run {
                        self.candidateURL = url
                        self.candidateDetails = details
                        self.pingPong = false
                        self.busy = false
                        self.status = "视频可读取，请选择质量。"
                    }
                } catch {
                    await MainActor.run {
                        self.busy = false
                        self.error = error.localizedDescription
                        self.status = "导入已停止"
                    }
                }
            }
        }
    }

    func importCandidate() {
        guard let url = candidateURL else { return }
        let inputDetails = candidateDetails
        let selectedQuality = quality
        let selectedPingPong = pingPong
        candidateURL = nil
        candidateDetails = nil
        busy = true
        error = nil
        status = "正在准备转换…"
        conversionProgress = nil
        let token = ConversionCancellation()
        cancellation = token
        canCancel = true
        Task.detached {
            let scratch = AerialPaths.userDefault.support.appendingPathComponent("Conversions/\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: scratch) }
            do {
                guard let inputDetails else { throw SwitcherError("视频信息已失效，请重新选择。") }
                let manager = CustomAerialManager()
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                let thumbnail = scratch.appendingPathComponent("thumbnail.jpg")
                try AVFoundationVideoInspector().thumbnail(url, to: thumbnail)
                let existingReport = !selectedPingPong && url.pathExtension.lowercased() == "mov"
                    ? try? AerialCompatibilityChecker().check(url, ffmpeg: FFmpegLocator.locate(), cancellation: token)
                    : nil
                let converted: ConvertedAerialVideo
                if let existingReport {
                    converted = .init(movie: url, details: inputDetails, report: existingReport)
                    await MainActor.run { self.status = "视频已兼容，正在安装…" }
                } else {
                    converted = try AerialVideoConverter().convert(url, details: inputDetails,
                        options: .init(quality: selectedQuality, pingPong: selectedPingPong),
                        scratch: scratch, cancellation: token,
                        progress: { value in
                            Task { @MainActor in
                                self.conversionProgress = value
                                self.status = value.stage
                            }
                        })
                }
                try token.requireActive()
                await MainActor.run {
                    self.conversionProgress = nil
                    self.canCancel = false
                    self.status = "正在安装已验证的视频…"
                }
                let asset = try manager.importConvertedVideo(converted.movie,
                    sourceFilename: url.lastPathComponent,
                    displayName: url.deletingPathExtension().lastPathComponent +
                        (selectedPingPong ? AppStrings.text(" · 往返") : ""),
                    thumbnail: thumbnail, progress: { message in
                    Task { @MainActor in self.status = message }
                })
                await MainActor.run { self.status = "动态壁纸已添加" }
                let refresh = Self.refreshExperimentalProcesses()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let processReport = refresh + "; 打开设置后：" + Self.processSnapshot()
                let diagnosis = "自定义壁纸已安装\nUUID: \(asset.id)\nmanifest: \(manager.paths.manifest.path)\n视频缓存: \(manager.paths.videos.appendingPathComponent(asset.id + ".mov").path)\n缩略图: \(manager.paths.thumbnails.appendingPathComponent(asset.id + ".png").path)\n\(processReport)"
                NSLog("DynamicWallpaperSwitcher import: %@", diagnosis)
                let items = try manager.list()
                await MainActor.run {
                    self.items = items
                    self.diagnosticText = diagnosis
                    self.status = "动态壁纸已添加。请在系统设置 → 墙纸 → 自定义中选择。"
                    self.localizationStatus = try? manager.localizationStatus()
                    self.busy = false
                    self.cancellation = nil
                    self.canCancel = false
                    self.conversionProgress = nil
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.status = "导入未完成"
                    self.busy = false
                    self.cancellation = nil
                    self.canCancel = false
                    self.conversionProgress = nil
                }
            }
        }
    }

    func cancelConversion() {
        cancellation?.cancel()
        status = "正在取消并清理临时文件…"
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticText, forType: .string)
        status = "诊断信息已复制"
    }

    func beginManifestControlTest() {
        runManifestDiagnostic("正在备份并调整 Mac Blue 排序…") { manager in
            let backup = try manager.beginManifestControlTest()
            return "控制测试已写入：Mac Blue preferredOrder = -999。请观察它是否移到 Mac 分类最前面。备份：\(backup)"
        }
    }

    func restoreManifestControlTest(observedChange: Bool) {
        runManifestDiagnostic("正在恢复 Mac Blue 原始清单…") { manager in
            try manager.restoreManifestControlTest(observedChange: observedChange)
            return observedChange ? "Mac Blue 原始清单已恢复；已记录你观察到排序变化，可以运行实验 2。" : "Mac Blue 原始清单已恢复；停止新增 asset 实验，请先查实际数据源。"
        }
    }

    func createMacBlueCloneTest() {
        runManifestDiagnostic("正在复制 Mac Blue 测试 asset…") { manager in
            let id = try manager.createMacBlueCloneTest()
            return "实验 2 已写入 Mac Blue 克隆：\(id)。请观察 Mac 分类是否出现第五张卡。未安装自定义视频。"
        }
    }

    func deleteMacBlueCloneTest() {
        runManifestDiagnostic("正在删除本 App 的 Mac Blue 克隆…") { manager in
            try manager.deleteMacBlueCloneTest()
            return "Mac Blue 克隆测试 asset 已删除。"
        }
    }

    private func runManifestDiagnostic(_ message: String, operation: @escaping (CustomAerialManager) throws -> String) {
        busy = true
        error = nil
        status = message
        Task.detached {
            do {
                let manager = CustomAerialManager()
                let outcome = try operation(manager)
                let refresh = Self.refreshExperimentalProcesses()
                await MainActor.run {
                    if let settings = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
                        NSWorkspace.shared.open(settings)
                    }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let state = try manager.manifestDiagnosticStatus()
                let diagnosis = "Manifest 两阶段诊断\n\(outcome)\nmanifest: \(manager.paths.manifest.path)\nMac Blue ID: 94383DC9-59D3-43EC-9E8E-A783DA633E06\n控制测试备份: \(state.backupPath ?? "无")\n控制组已观察到变化: \(state.controlConfirmed ? "是" : "尚未")\n克隆 UUID: \(state.cloneID ?? "无")\n\(refresh)\n刷新后: \(Self.processSnapshot())\n\nAerials 窄日志（最近 2 分钟）：\n\(Self.recentAerialLogs())"
                NSLog("DynamicWallpaperSwitcher manifest diagnostic: %@", diagnosis)
                await MainActor.run {
                    self.manifestStatus = state
                    self.diagnosticText = diagnosis
                    self.status = outcome
                    self.busy = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.status = "操作未完成；请检查状态后再试。"
                    self.busy = false
                }
            }
        }
    }

    func repair(_ id: String) { run("正在修复…") { try CustomAerialManager().repair(id) } }

    func activateFormalCategory() {
        run("正在备份本地化资源并创建独立自定义分类…") {
            try CustomAerialManager().activateFormalCustomCategory()
        }
    }

    func repairCategoryName() {
        run("正在以当前资源为基准修复分类名称…") {
            try CustomAerialManager().repairCustomCategoryLocalization()
        }
    }

    func restoreLocalization() {
        run("正在恢复本 App 备份的本地化资源…") {
            try CustomAerialManager().restoreOriginalLocalization()
        }
    }

    func repairAll() {
        busy = true
        error = nil
        status = "正在检查并修复全部资源…"
        Task.detached {
            let failures = CustomAerialManager().repairAll()
            let result = try? CustomAerialManager().list()
            await MainActor.run {
                if let result { self.items = result }
                self.error = failures.isEmpty ? nil : failures.joined(separator: "\n")
                self.status = failures.isEmpty ? "全部检查完成" : "部分资源需要处理"
                self.busy = false
            }
        }
    }

    func delete(_ id: String) { run("正在删除…") { try CustomAerialManager().delete(id) } }

    func migrate(_ id: String) { run("正在迁移旧版壁纸…") { try CustomAerialManager().migrateLegacy(id) } }

    private func run(_ message: String, operation: @escaping () throws -> Void) {
        busy = true
        error = nil
        status = message
        Task.detached {
            do {
                try operation()
                _ = Self.refreshExperimentalProcesses()
                await MainActor.run {
                    if let settings = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
                        NSWorkspace.shared.open(settings)
                    }
                }
                let manager = CustomAerialManager()
                let result = try manager.list()
                let localizationStatus = try? manager.localizationStatus()
                let experimental = result.first { $0.asset.mode == .experimental }
                let diagnosis = experimental.flatMap {
                    try? manager.experimentalDiagnostics($0.id, processReport: "操作后：" + Self.processSnapshot())
                }
                await MainActor.run {
                    self.items = result
                    self.localizationStatus = localizationStatus
                    self.diagnosticText = diagnosis ?? ""
                    self.status = AppStrings.text("操作完成；请在系统设置 → 墙纸中查看。")
                    self.busy = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.status = "操作未完成"
                    self.busy = false
                }
            }
        }
    }

    nonisolated private static func processSnapshot() -> String {
        ["WallpaperAerialsExtension", "WallpaperAgent"].map { name in
            let task = Process()
            let output = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            task.arguments = ["-U", String(getuid()), "-x", name]
            task.standardOutput = output
            task.standardError = Pipe()
            do {
                try task.run()
                task.waitUntilExit()
                let pids = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return "\(name)=\(pids.isEmpty ? "未运行" : pids.replacingOccurrences(of: "\n", with: ","))"
            } catch { return "\(name)=检查失败：\(error.localizedDescription)" }
        }.joined(separator: "，")
    }

    nonisolated private static func refreshExperimentalProcesses() -> String {
        let before = processSnapshot()
        var results: [String] = []
        // Restarting idleassetsd can replace a user-modified Aerials catalog with an older
        // downloaded manifest. Refresh only the wallpaper UI processes here.
        for name in ["WallpaperAerialsExtension", "WallpaperAgent", "System Settings"] {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            task.arguments = ["-U", String(getuid()), "-x", name]
            task.standardError = Pipe()
            do {
                try task.run()
                task.waitUntilExit()
                let code = task.terminationStatus
                results.append("\(name): \(code == 0 ? "已发送重启信号" : code == 1 ? "原进程未运行" : "结束失败(\(code))")")
            } catch { results.append("\(name): 结束失败(\(error.localizedDescription))") }
        }
        Thread.sleep(forTimeInterval: 2)
        return "刷新前：\(before)；刷新操作：\(results.joined(separator: "，"))"
    }

    nonisolated private static func recentAerialLogs() -> String {
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        task.arguments = ["show", "--last", "2m", "--style", "compact", "--info", "--predicate",
                          "process == \"WallpaperAerialsExtension\" AND (eventMessage CONTAINS[c] \"manifest\" OR eventMessage CONTAINS[c] \"provideSettingsViewModels\" OR eventMessage CONTAINS[c] \"CUSTOM_TEST\" OR eventMessage CONTAINS[c] \"MAC_WP_BLU\" OR eventMessage CONTAINS[c] \"invalid\" OR eventMessage CONTAINS[c] \"localized\" OR eventMessage CONTAINS[c] \"filter\" OR eventMessage CONTAINS[c] \"skip\" OR eventMessage CONTAINS[c] \"unknown\")"]
        task.standardOutput = output
        task.standardError = output
        do {
            try task.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let lines = (String(data: data, encoding: .utf8) ?? "").split(separator: "\n")
            return lines.suffix(80).joined(separator: "\n").isEmpty ? "无匹配日志" : lines.suffix(80).joined(separator: "\n")
        } catch { return "日志读取失败：\(error.localizedDescription)" }
    }
}

struct CustomAerialsView: View {
    @StateObject private var model = CustomAerialsViewModel()
    @State private var pendingDelete: String?
    @State private var pendingMigration: String?

    private var customItems: [CustomAssetHealth] { model.items.filter { $0.asset.mode == .custom } }
    private var legacyItems: [CustomAssetHealth] { model.items.filter { $0.asset.mode == .legacy } }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("自定义动态壁纸").font(.title2.bold())
                    Text("将普通视频转换为 macOS 原生 Aerial 动态壁纸。锁屏时播放，解锁后自然停留在桌面背景。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("+ 添加视频") { model.chooseVideo() }
                    .buttonStyle(.borderedProminent).disabled(model.busy)
            }
            HStack(spacing: 12) {
                Text("环境").font(.footnote.bold())
                Text(model.dependencies.ffmpeg == nil ? "ffmpeg 未找到" : "ffmpeg ✓")
                Text(model.dependencies.ffprobe == nil ? "ffprobe 未找到" : "ffprobe ✓")
                Text(model.dependencies.x265 == nil ? "x265 未找到" : "x265 ✓")
                if let architecture = model.dependencies.x265Architecture { Text(AppStrings.text(architecture)) }
            }.font(.footnote).foregroundStyle(model.dependencies.ready ? Color.secondary : Color.orange)

            Text("我的动态壁纸").font(.headline)
            if customItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)
                    Text("还没有自定义壁纸").font(.headline)
                    Text("选择 MOV 或 MP4 视频开始导入。").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 190)
            } else {
                LazyVStack(spacing: 10) { ForEach(customItems) { item in row(item) } }
            }
            DisclosureGroup("高级设置") {
            VStack(alignment: .leading, spacing: 10) {
            Text("App 架构：Universal（Intel + Apple Silicon）")
            Text(String(format: AppStrings.text("当前运行：%@"), RuntimeArchitecture.label))
            if let ffmpeg = model.dependencies.ffmpeg { Text(String(format: AppStrings.text("ffmpeg：%@"), ffmpeg.path)) }
            if let x265 = model.dependencies.x265 { Text(String(format: AppStrings.text("x265：%@"), x265.path)) }
            if let version = model.dependencies.x265Version { Text(version).lineLimit(2) }
            HStack {
                if model.localizationStatus?.categoryPresent == true {
                    Label("独立“自定义”分类已启用", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("启用独立“自定义”分类") { model.activateFormalCategory() }
                        .disabled(model.busy || customItems.isEmpty)
                }
                Button("修复自定义分类名称") { model.repairCategoryName() }
                    .disabled(model.busy || model.localizationStatus?.needsRepair != true)
                Button("恢复原本地化资源") { model.restoreLocalization() }
                    .disabled(model.busy || model.localizationStatus?.categoryPresent == true
                              || model.localizationStatus?.backupPath == nil)
            }
            if model.localizationStatus?.needsRepair == true {
                Text("系统墙纸资源已更新，需要修复自定义分类名称。")
                    .foregroundStyle(.orange)
            }
            if !legacyItems.isEmpty {
                DisclosureGroup(String(format: AppStrings.text("旧版自定义壁纸（%lld）"), legacyItems.count)) {
                    Text("迁移会保留原 UUID 和视频主副本，改用当前自定义分类。旧 MP4 素材只搬迁文件，播放兼容性仍需实机确认。")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(legacyItems) { item in
                        HStack {
                            Text(item.asset.displayName)
                            Spacer()
                            Button("迁移旧版自定义壁纸") { pendingMigration = item.id }
                                .disabled(model.busy)
                        }.padding(8)
                    }
                }
            }
            #if DEBUG
            DisclosureGroup("开发者诊断") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("已完成的 A/B 控件保留供排查使用；正常导入不需要运行。")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Button("Manifest 控制测试") { model.beginManifestControlTest() }
                            .disabled(model.busy || model.manifestStatus?.controlActive == true || model.manifestStatus?.cloneID != nil)
                        Button("恢复 Manifest 控制测试") { model.restoreManifestControlTest(observedChange: false) }
                            .disabled(model.busy || model.manifestStatus?.controlActive != true)
                        Button("Mac Blue 已前移：恢复并解锁实验 2") { model.restoreManifestControlTest(observedChange: true) }
                            .disabled(model.busy || model.manifestStatus?.controlActive != true)
                    }
                    HStack {
                        Button("新增 Mac Blue 克隆测试卡") { model.createMacBlueCloneTest() }
                            .disabled(model.busy || model.manifestStatus?.controlConfirmed != true || model.manifestStatus?.controlActive == true || model.manifestStatus?.cloneID != nil)
                        Button("删除本次克隆测试卡") { model.deleteMacBlueCloneTest() }
                            .disabled(model.busy || model.manifestStatus?.cloneID == nil)
                    }
                    if let id = model.manifestStatus?.cloneID { Text("克隆 UUID: \(id)").font(.caption.monospaced()) }
                    if !model.diagnosticText.isEmpty {
                        HStack { Text("诊断信息").font(.headline); Spacer(); Button("复制诊断信息") { model.copyDiagnostics() } }
                        Text(model.diagnosticText).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }.padding(.top, 6)
            }
            #endif
            }.font(.footnote)
            }

            if let error = model.error {
                Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }
            HStack {
                if let conversion = model.conversionProgress {
                    VStack(alignment: .leading, spacing: 3) {
                        ProgressView(value: conversion.fraction)
                        Text(String(format: AppStrings.text("已处理 %@ / %@ 秒 · %d%%"),
                                    String(format: "%.1f", conversion.elapsedVideoSeconds),
                                    String(format: "%.1f", Double(conversion.totalFrames) / 240),
                                    Int(conversion.fraction * 100)) +
                             (conversion.remainingSeconds.map {
                                String(format: AppStrings.text(" · 预计剩余约 %d 分钟"), Int($0 / 60) + 1)
                             } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(width: 220)
                } else if model.busy { ProgressView().controlSize(.small) }
                Text(AppStrings.text(model.status)).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                if model.busy && model.canCancel {
                    Button("取消") { model.cancelConversion() }
                }
                Button("打开墙纸设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .padding(22)
        }
        .sheet(isPresented: Binding(
            get: { model.candidateURL != nil },
            set: { if !$0 { model.candidateURL = nil } }
        )) {
            VStack(alignment: .leading, spacing: 14) {
                Text("添加自定义动态壁纸").font(.title3.bold())
                Text(model.candidateURL?.lastPathComponent ?? "").lineLimit(2)
                if let details = model.candidateDetails {
                    Text(String(format: AppStrings.text("视频：%@"), details.codec))
                    Text(String(format: AppStrings.text("分辨率：%lld×%lld"), details.width, details.height))
                    Text(String(format: AppStrings.text("帧率：%lld fps"), Int(details.frameRate.rounded())))
                    Text(String(format: AppStrings.text("长度：%@ 秒"), String(format: "%.1f", details.duration)))
                    let size = AerialResolution.output(width: details.width, height: details.height)
                    Text(String(format: AppStrings.text("输出：%lld×%lld · 240 fps"), size.0, size.1))
                    if model.candidateWarning {
                        Text(AppStrings.text(model.pingPong ? "往返成片最多 4 分钟，请选择较短的视频。" : "当前版本最多转换 4 分钟视频。"))
                            .foregroundStyle(.orange)
                    }
                }
                Picker("画质", selection: $model.quality) {
                    ForEach(QualityPreset.allCases) { preset in
                        Text(AppStrings.text(preset.label)).tag(preset)
                    }
                }.pickerStyle(.radioGroup)
                Toggle("正放后倒放（首尾相接）", isOn: $model.pingPong)
                if model.pingPong, let details = model.candidateDetails {
                    Text(String(format: AppStrings.text("预计成片约 %@ 秒；会去掉两端重复画面。"),
                                String(format: "%.1f", details.duration * 2)))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("高质量文件更大、转换更慢；推荐标准。").font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("取消") { model.candidateURL = nil }
                    Button("开始转换") { model.importCandidate() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.dependencies.ready || model.candidateWarning)
                }
            }
            .padding(24)
            .frame(width: 420)
        }
        .confirmationDialog("删除这张自定义壁纸？", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let id = pendingDelete { model.delete(id) }
                pendingDelete = nil
            }
        } message: {
            Text("只删除本 App 管理的资源；不会触及 Apple、Golden Gate 或其他自定义壁纸。")
        }
        .confirmationDialog("迁移这张旧版壁纸？", isPresented: Binding(
            get: { pendingMigration != nil }, set: { if !$0 { pendingMigration = nil } }
        )) {
            Button("迁移") {
                if let id = pendingMigration { model.migrate(id) }
                pendingMigration = nil
            }
        } message: {
            Text("保留 UUID 与主副本；旧 MP4 视频的播放兼容性未验证。")
        }
    }

    private func row(_ item: CustomAssetHealth) -> some View {
        let asset = item.asset
        let thumb = AerialPaths.userDefault.support.appendingPathComponent("CustomAerials/Assets/\(asset.id)/thumbnail.jpg")
        return HStack(alignment: .top, spacing: 14) {
            if let image = NSImage(contentsOf: thumb) {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: 126, height: 78).clipped().cornerRadius(7)
            } else {
                Image(systemName: "film").frame(width: 126, height: 78)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(asset.displayName).font(.headline)
                Text(asset.sourceFilename).font(.footnote).foregroundStyle(.secondary)
                Text(String(format: AppStrings.text("%lld×%lld · %lld 秒"),
                            asset.details.width, asset.details.height, Int(asset.details.duration.rounded())))
                    .font(.footnote)
                if asset.compatibilityValidated {
                    Label("动态壁纸兼容 ✓", systemImage: "checkmark.seal.fill")
                        .font(.footnote).foregroundStyle(.green)
                } else {
                    Text("旧版导入 · 解锁兼容性未验证").font(.footnote).foregroundStyle(.orange)
                }
                Text(asset.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                Text(AppStrings.text(statusText(item))).font(.footnote)
                    .foregroundStyle(item.isHealthy ? .green : .orange)
                HStack(spacing: 10) {
                    Button("选择") { openWallpaperSettings() }
                    Button("修复") { model.repair(asset.id) }.disabled(model.busy)
                    Button("在 Finder 中显示") {
                        let cache = AerialPaths.userDefault.videos.appendingPathComponent(asset.id + ".mov")
                        let original = AerialPaths.userDefault.support.appendingPathComponent("CustomAerials/Assets/\(asset.id)/original.mov")
                        NSWorkspace.shared.activateFileViewerSelecting([item.cachePresent ? cache : original])
                    }
                    Button("删除", role: .destructive) { pendingDelete = asset.id }.disabled(model.busy)
                }
                .buttonStyle(.link)
                .font(.footnote)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func statusText(_ item: CustomAssetHealth) -> String {
        if !item.originalPresent { return "⚠ 主副本丢失" }
        if !item.manifestPresent { return "⚠ manifest 条目丢失" }
        if !item.cachePresent { return "⚠ 视频缓存丢失" }
        if !item.thumbnailPresent { return "⚠ 缩略图丢失" }
        if !item.hashMatches { return "⚠ 视频校验不匹配" }
        return "✓ 已安装"
    }

    private func openWallpaperSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
