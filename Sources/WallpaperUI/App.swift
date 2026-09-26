import SwiftUI
import AppKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
}

@MainActor private enum AppServices {
    static let model = LibraryModel()
    static let catalog = UnifiedLibrary(model: model)
}

@MainActor final class WallpaperAppDelegate: NSObject, NSApplicationDelegate {
    private var polling: Task<Void, Never>?
    private var sleepObserver: NSObjectProtocol?
    private var lockObserver: NSObjectProtocol?
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppServices.catalog.start()
        polling = Task {
            await AppServices.model.recoverBackdrops()
            while !Task.isCancelled {
                await AppServices.model.refreshState()
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in await AppServices.model.stopScene() }
            }
        lockObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in await AppServices.model.stopScene() }
            }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        AppServices.catalog.stop()
        Task {
            // Shutdown must see an in-flight video activation before polling
            // cancellation can erase it; the model owns cancellation/rollback.
            await AppServices.model.shutdownScene()
            polling?.cancel()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main @MainActor struct WallpaperApp: App {
    @NSApplicationDelegateAdaptor(WallpaperAppDelegate.self) private var delegate
    @StateObject private var model = AppServices.model
    @AppStorage("appAppearance") private var appearance = AppAppearance.system
    @AppStorage("libraryPage") private var page = LibraryPage.library
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        Window("壁纸", id: "library") {
            NativeLibraryView().environmentObject(model).environmentObject(model.scenePlayer).environmentObject(AppServices.catalog)
                .preferredColorScheme(appearance.colorScheme).frame(minWidth: 980, minHeight: 680)
        }.defaultSize(width: 1200, height: 800)
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("设置…") {
                        page = .settings
                        openWindow(id: "library")
                        NSApp.activate(ignoringOtherApps: true)
                    }.keyboardShortcut(",", modifiers: .command)
                }
                CommandGroup(after: .sidebar) {
                    Menu("外观") {
                        Picker("外观", selection: $appearance) {
                            ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                        }.pickerStyle(.inline)
                    }
                    Divider()
                    Button("紧凑窗口") { resizeWindow(width: 980, height: 680) }
                    Button("标准窗口") { resizeWindow(width: 1200, height: 800) }
                    Divider()
                    Button("停止所有壁纸") { Task { await model.perform(.off) } }
                        .keyboardShortcut(".", modifiers: [.command, .option])
                }
            }
        MenuBarExtra("壁纸", systemImage: "desktopcomputer") {
            WallpaperMenu().environmentObject(model).environmentObject(model.scenePlayer)
        }
    }
    private func resizeWindow(width: CGFloat, height: CGFloat) {
        guard let window = NSApp.keyWindow, window.sheetParent == nil, window.attachedSheet == nil else { return }
        window.setContentSize(NSSize(width: width, height: height))
    }
}

private struct WallpaperMenu: View {
    @EnvironmentObject var model: LibraryModel
    @EnvironmentObject var scenePlayer: ScenePlayer
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(scenePlayer.isActive ? scenePlayer.statusText : model.state.running ? "视频正在桌面播放" : "壁纸已停止")
        if scenePlayer.isActive { Text(scenePlayer.title) }
        Button("打开资料库") {
            openWindow(id: "library")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("停止所有壁纸") { Task { await model.perform(.off) } }
            .disabled(model.busy || scenePlayer.phase == .stopping)
        if scenePlayer.restorationPending {
            Button("恢复原壁纸") { Task { await scenePlayer.recoverBackdrop() } }
                .disabled(scenePlayer.isActive || scenePlayer.recoveringBackdrop)
        }
        if model.videoBackdrop.restorationPending {
            Button("恢复视频底图前的壁纸") { Task { await model.recoverVideoBackdrop() } }
                .disabled(model.isWorking)
        }
        Divider()
        Button("退出壁纸") { NSApp.terminate(nil) }
    }
}
