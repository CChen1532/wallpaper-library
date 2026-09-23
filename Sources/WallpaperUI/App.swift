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

@main struct WallpaperApp: App {
    @StateObject private var model = LibraryModel()
    @AppStorage("appAppearance") private var appearance = AppAppearance.system
    var body: some Scene {
        WindowGroup("视频壁纸") {
            NativeLibraryView().environmentObject(model).preferredColorScheme(appearance.colorScheme).frame(minWidth: 980, minHeight: 680)
        }.defaultSize(width: 1200, height: 800)
            .commands {
                CommandGroup(after: .sidebar) {
                    Menu("外观") {
                        Picker("外观", selection: $appearance) {
                            ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                        }.pickerStyle(.inline)
                    }
                    Divider()
                    Button("紧凑窗口") { resizeWindow(width: 980, height: 680) }
                    Button("标准窗口") { resizeWindow(width: 1200, height: 800) }
                }
            }
    }
    private func resizeWindow(width: CGFloat, height: CGFloat) {
        guard let window = NSApp.keyWindow, window.sheetParent == nil, window.attachedSheet == nil else { return }
        window.setContentSize(NSSize(width: width, height: height))
    }
}
