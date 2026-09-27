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
    static let workshop = WorkshopModel(findExisting: { id in
        let candidates = catalog.scenes.map(\.folder) + model.items.map { $0.url.deletingLastPathComponent() }
        return candidates.first { $0.lastPathComponent == id && FileManager.default.fileExists(atPath: $0.appendingPathComponent("project.json").path) }
    }, libraryBusy: { model.isWorking }, onImported: { folder in
        catalog.addFolder(folder)
        await catalog.refresh()
    })
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
        AppServices.workshop.cancel()
        Task {
            // Shutdown must see an in-flight video activation before polling
            // cancellation can erase it; the model owns cancellation/rollback.
            await AppServices.model.shutdownScene()
            await AppServices.workshop.shutdown()
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
    @AppStorage("appLanguage") private var language = AppLanguage.chinese
    @AppStorage("libraryPage") private var page = LibraryPage.library
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        Window(AppStrings.text("壁纸", language: language), id: "library") {
            NativeLibraryView().environmentObject(model).environmentObject(model.scenePlayer).environmentObject(AppServices.catalog).environmentObject(AppServices.workshop)
                .environment(\.locale, language.locale)
                .preferredColorScheme(appearance.colorScheme).frame(minWidth: 980, minHeight: 680)
        }.defaultSize(width: 1200, height: 800)
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button(AppStrings.text("设置…", language: language)) {
                        page = .settings
                        openWindow(id: "library")
                        NSApp.activate(ignoringOtherApps: true)
                    }.keyboardShortcut(",", modifiers: .command)
                }
                CommandGroup(after: .sidebar) {
                    Button(AppStrings.text("创意工坊", language: language)) {
                        page = .workshop; openWindow(id: "library"); NSApp.activate(ignoringOtherApps: true)
                    }.keyboardShortcut("2", modifiers: .command)
                    Menu(AppStrings.text("外观", language: language)) {
                        Picker(AppStrings.text("外观", language: language), selection: $appearance) {
                            ForEach(AppAppearance.allCases) { Text(AppStrings.text($0.label, language: language)).tag($0) }
                        }.pickerStyle(.inline)
                    }
                    Divider()
                    Button(AppStrings.text("紧凑窗口", language: language)) { resizeWindow(width: 980, height: 680) }
                    Button(AppStrings.text("标准窗口", language: language)) { resizeWindow(width: 1200, height: 800) }
                    Divider()
                    Button(AppStrings.text(model.scenePlayer.manualPause ? "继续场景" : "暂停场景", language: language)) { model.scenePlayer.togglePause() }
                        .keyboardShortcut("p", modifiers: [.command, .option]).disabled(!model.scenePlayer.supportsControls)
                    Button(AppStrings.text("停止所有壁纸", language: language)) { Task { await model.perform(.off) } }
                        .keyboardShortcut(".", modifiers: [.command, .option])
                }
            }
        MenuBarExtra(AppStrings.text("壁纸", language: language), systemImage: "desktopcomputer") {
            WallpaperMenu().environmentObject(model).environmentObject(model.scenePlayer)
                .environment(\.locale, language.locale)
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
    @Environment(\.locale) private var locale
    var body: some View {
        Text(AppStrings.text(scenePlayer.isActive ? scenePlayer.statusText : model.state.running ? "视频正在桌面播放" : "壁纸已停止", locale: locale))
        if scenePlayer.isActive { Text(scenePlayer.title) }
        Button("打开资料库") {
            openWindow(id: "library")
            NSApp.activate(ignoringOtherApps: true)
        }
        if scenePlayer.supportsControls {
            Button(LocalizedStringKey(scenePlayer.manualPause ? "继续场景" : "暂停场景")) { scenePlayer.togglePause() }
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
