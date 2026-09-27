import AppKit
import Foundation
import IOKit.ps

struct ScenePowerEnvironment: Sendable {
    var onBattery = false
    var lowPower = false
    var thermal = 0
    var covered = false

    @MainActor static func current(displayID: UInt32?, checkCoverage: Bool = true) -> Self {
        var value = Self()
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
            value.onBattery = (source as String) == kIOPSBatteryPowerValue
        }
        value.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        value.thermal = ProcessInfo.processInfo.thermalState.rawValue
        if checkCoverage, let displayID, let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           front.bundleIdentifier != "com.apple.finder",
           let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            let screen = CGDisplayBounds(displayID)
            value.covered = windows.contains { window in
                guard (window[kCGWindowOwnerPID as String] as? Int32) == front.processIdentifier,
                      (window[kCGWindowLayer as String] as? Int) == 0,
                      (window[kCGWindowAlpha as String] as? Double ?? 1) > 0.9,
                      let bounds = window[kCGWindowBounds as String] as? [String: Any],
                      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), screen.width > 0, screen.height > 0 else { return false }
                let overlap = rect.intersection(screen)
                return overlap.width * overlap.height >= screen.width * screen.height * 0.95
            }
        }
        return value
    }
}

struct ScenePowerDecision: Equatable, Sendable {
    let state: String
    let fps: Int
    let reason: String?
    static func resolve(_ preferences: ScenePreferences, manualPause: Bool, environment: ScenePowerEnvironment) -> Self {
        if manualPause { return .init(state: "pause", fps: preferences.fps, reason: "场景已暂停") }
        if preferences.pauseWhenCovered && environment.covered {
            return .init(state: "pause", fps: preferences.fps, reason: "屏幕被覆盖，场景已暂停")
        }
        if preferences.energySaving && environment.thermal >= 3 {
            return .init(state: "pause", fps: preferences.fps, reason: "设备温度较高，场景已暂停")
        }
        if preferences.energySaving && (environment.onBattery || environment.lowPower || environment.thermal >= 2) {
            return .init(state: "throttle", fps: min(15, preferences.fps), reason: "场景正在节能播放")
        }
        return .init(state: "run", fps: preferences.fps, reason: nil)
    }
}

enum SceneExportAction: Sendable { case screenshot(URL), storage(URL), resetStorage(URL) }

enum SceneShortcut {
    /// The event must match a configured property; only URLs/files chosen for
    /// that wallpaper can be opened. Shell commands and arbitrary schemes are rejected.
    static func target(_ raw: String) -> URL? {
        guard !raw.isEmpty, raw.count <= 4096,
              !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        if let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
           url.host?.isEmpty == false, url.user == nil, url.password == nil { return url }
        let url: URL
        if raw.hasPrefix("/") { url = URL(fileURLWithPath: raw) }
        else if let file = URL(string: raw), file.isFileURL { url = file }
        else { return nil }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: canonical.path) else { return nil }
        let values = try? canonical.resourceValues(forKeys: [.isDirectoryKey, .isExecutableKey])
        if canonical.pathExtension.lowercased() == "app", values?.isDirectory == true { return canonical }
        if values?.isDirectory == true { return canonical }
        let safe = ["png", "jpg", "jpeg", "heic", "gif", "webp", "pdf", "txt", "md", "mp4", "mov", "mp3", "m4a", "wav"]
        return safe.contains(canonical.pathExtension.lowercased()) && values?.isExecutable != true ? canonical : nil
    }
}
