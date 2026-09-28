import SwiftUI
import AppKit
import Foundation
import Darwin

@MainActor
final class SwitcherViewModel: ObservableObject {
    @Published var current = "读取中…"
    @Published var progress = "正在检查视频和备份…"
    @Published var error: String?
    @Published var busy = true
    @Published var hasGoldenPortrait = false
    @Published var hasPendingTransaction = false

    init() { refresh() }

    func refresh() {
        busy = true
        error = nil
        progress = "正在检查视频和备份…"
        Task.detached {
            do {
                let switcher = WallpaperSwitcher()
                try switcher.prepare(progress: { message in
                    Task { @MainActor in self.progress = message }
                })
                let state = try switcher.status()
                await MainActor.run {
                    self.current = Self.label(state)
                    self.hasGoldenPortrait = switcher.hasGoldenPortraitPair()
                    self.progress = "就绪"
                    self.busy = false
                    self.hasPendingTransaction = false
                }
            } catch {
                await MainActor.run {
                    self.current = "未知"
                    self.progress = "检查未完成"
                    self.error = error.localizedDescription
                    self.hasPendingTransaction = !WallpaperSwitcher().pendingTransactions().isEmpty
                    self.busy = false
                }
            }
        }
    }

    func recoverInterrupted() {
        busy = true
        error = nil
        progress = "正在从事务副本恢复…"
        Task.detached {
            do {
                try WallpaperSwitcher().recoverInterrupted()
                _ = Self.restartWallpaperProcesses()
                await MainActor.run { self.refresh() }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.busy = false
                }
            }
        }
    }

    func use(_ state: WallpaperState, reset: Bool = false) {
        busy = true
        error = nil
        progress = "正在准备切换…"
        Task.detached {
            do {
                let switcher = WallpaperSwitcher()
                let report: (String) -> Void = { message in
                    Task { @MainActor in self.progress = message }
                }
                if reset { try switcher.reset(progress: report) }
                else { try switcher.switchTo(state, progress: report) }
                await MainActor.run { self.progress = "正在刷新系统壁纸进程…" }
                let restartNote = Self.restartWallpaperProcesses()
                let actual = try switcher.status()
                await MainActor.run {
                    self.current = Self.label(actual)
                    self.hasGoldenPortrait = switcher.hasGoldenPortraitPair()
                    self.progress = restartNote ?? (reset ? "已恢复 Tahoe，并清理横屏缓存" : "切换完成")
                    self.busy = false
                }
            } catch {
                await MainActor.run {
                    self.progress = "操作失败"
                    self.error = error.localizedDescription
                    self.busy = false
                }
            }
        }
    }

    private static func label(_ state: WallpaperState) -> String {
        switch state {
        case .tahoe: "Tahoe"
        case .goldenGate: "Golden Gate"
        case .unknown: "未知 / 已修改"
        }
    }

    nonisolated static func restartWallpaperProcesses() -> String? {
        var issues: [String] = []
        for name in ["WallpaperAgent", "NeptuneOneWallpaper"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            process.arguments = ["-U", String(getuid()), "-x", name]
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus > 1 { issues.append(name) }
            } catch { issues.append(name) }
        }
        return issues.isEmpty ? nil : "视频已切换；无法刷新：\(issues.joined(separator: "、"))。可注销后重新登录。"
    }
}

struct NeptuneView: View {
    @StateObject private var model = SwitcherViewModel()
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 30))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("DynamicWallpaperSwitcher").font(.title2.bold())
                    Text("Neptune 原生动态壁纸素材切换").foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("当前壁纸").foregroundStyle(.secondary)
                Spacer()
                Text(model.current).font(.headline)
            }
            .padding(14)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 12) {
                Button("使用 Tahoe") { model.use(.tahoe) }
                Button("使用 Golden Gate") { model.use(.goldenGate) }
                    .buttonStyle(.borderedProminent)
            }
            .disabled(model.busy)

            HStack(spacing: 8) {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.progress).foregroundStyle(.secondary)
            }

            if let error = model.error {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.hasPendingTransaction {
                Button("恢复上次中断的切换") { model.recoverInterrupted() }
                    .disabled(model.busy)
            }

            Text(model.hasGoldenPortrait
                 ? "已发现一对 Golden Gate 竖屏视频；切换时会一并使用。"
                 : "竖屏保持 Tahoe；仅当应用数据 GoldenGate 目录中有两段竖屏视频时才替换。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            HStack {
                Button("清理 / 重置为 Tahoe…") { confirmReset = true }
                    .disabled(model.busy)
                Spacer()
                Button("重新检查") { model.refresh() }
                    .disabled(model.busy)
            }
        }
        .padding(24)
        .frame(width: 470)
        .alert("恢复 Tahoe 并清理缓存？", isPresented: $confirmReset) {
            Button("取消", role: .cancel) {}
            Button("恢复 Tahoe") { model.use(.tahoe, reset: true) }
        } message: {
            Text("四个 Tahoe 视频将从首次备份恢复；应用缓存的两段 Golden Gate 横屏副本会被清理。竖屏素材、Aerials 原视频和实验克隆不会改动。")
        }
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            NeptuneView()
                .tabItem { Label("Apple 动态壁纸", systemImage: "mountain.2") }
            CustomAerialsView()
                .tabItem { Label("自定义壁纸", systemImage: "film.stack") }
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}

@main
struct DynamicWallpaperSwitcherApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .windowResizability(.contentSize)
    }
}
