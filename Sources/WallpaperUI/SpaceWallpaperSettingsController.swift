import AppKit
import ApplicationServices
import Foundation

/// A matching plist read is only a sample: WallpaperAgent may still finish an
/// older registration write and temporarily replace the all-Spaces selection.
/// Require a run of closely spaced matching observations before the renderer
/// is allowed to cover the system desktop picture.
struct SystemWallpaperStabilityGate {
    static let requiredDuration: TimeInterval = 3
    static let maximumSampleGap: TimeInterval = 0.6

    private var matchingSince: TimeInterval?
    private var previousSample: TimeInterval?

    mutating func observe(matches: Bool, at uptime: TimeInterval) -> Bool {
        guard uptime.isFinite else {
            matchingSince = nil
            previousSample = nil
            return false
        }
        defer { previousSample = uptime }
        guard matches else {
            matchingSince = nil
            return false
        }
        guard let previousSample, let matchingSince,
              uptime >= previousSample,
              uptime - previousSample <= Self.maximumSampleGap else {
            self.matchingSince = uptime
            return false
        }
        return uptime - matchingSince >= Self.requiredDuration
    }
}

/// Drives only the macOS Wallpaper pane's identified all-Spaces switch.
/// A manual trial of this system action updated Mission Control's thumbnails
/// where editing Index.plist alone did not. Accessibility permission is
/// required for the signed WallpaperUI app.
enum SpaceWallpaperSettingsController {
    @MainActor static func activate(displayID: UInt32, imageURL: URL) async throws {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(prompt) else {
            throw BackendError.message("自动匹配 Space 底图需要给“视频壁纸”辅助功能权限；请在系统设置→隐私与安全性→辅助功能中允许，然后重试")
        }
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { throw BackendError.message("目标显示器已断开，未切换系统底图") }
        try NSWorkspace.shared.setDesktopImageURL(imageURL, for: screen, options: [:])
        guard NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL == imageURL.standardizedFileURL else {
            throw BackendError.message("系统未登记当前场景静帧，自动底图已取消")
        }
        // setDesktopImageURL returns before WallpaperAgent has rebuilt its
        // per-Space selections. Pressing the Settings switch during that
        // rewrite can be undone by the later registration write.
        try await waitForRegistration(imageURL: imageURL)
        guard let pane = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"),
              NSWorkspace.shared.open(pane) else {
            throw BackendError.message("无法打开系统墙纸设置，自动底图已取消")
        }
        try await setAllSpacesOn(imageURL: imageURL)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func findSwitch(_ element: AXUIElement, remaining: inout Int) -> AXUIElement? {
        guard remaining > 0 else { return nil }
        remaining -= 1
        if attribute(element, "AXIdentifier") as? String == "ShowOnAllDisplays" { return element }
        for key in [kAXChildrenAttribute as String, "AXContents"] {
            guard let children = attribute(element, key) as? [AXUIElement] else { continue }
            for child in children {
                if let found = findSwitch(child, remaining: &remaining) { return found }
            }
        }
        return nil
    }

    private static func allSpacesSwitch(in app: NSRunningApplication) -> AXUIElement? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows = attribute(root, kAXWindowsAttribute as String) as? [AXUIElement] else { return nil }
        var remaining = 4000
        for window in windows {
            if let control = findSwitch(window, remaining: &remaining) { return control }
        }
        return nil
    }

    private static func switchValue(_ element: AXUIElement) -> Bool? {
        if let number = attribute(element, kAXValueAttribute as String) as? NSNumber { return number.boolValue }
        if let string = attribute(element, kAXValueAttribute as String) as? String {
            if string == "on" || string == "1" { return true }
            if string == "off" || string == "0" { return false }
        }
        return nil
    }

    private static func wallpaperDocument() -> [String: Any]? {
        let store = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        guard let data = try? Data(contentsOf: store) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private static func imageMatches(_ desktop: Any?, _ imageURL: URL) -> Bool {
        guard let desktop = desktop as? [String: Any],
              let content = desktop["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]], choices.count == 1,
              let files = choices[0]["Files"] as? [[String: String]], files.count == 1,
              let relative = files[0]["relative"], let url = URL(string: relative) else { return false }
        return url.standardizedFileURL == imageURL.standardizedFileURL
    }

    private static func registrationMatches(_ imageURL: URL) -> Bool {
        guard let document = wallpaperDocument(),
              let spaces = document["Spaces"] as? [String: Any], !spaces.isEmpty,
              let all = document["AllSpacesAndDisplays"] as? [String: Any],
              all["Type"] as? String == "idle" else { return false }
        return spaces.values.allSatisfy { value in
            guard let space = value as? [String: Any],
                  let selection = space["Default"] as? [String: Any] else { return false }
            return imageMatches(selection["Desktop"], imageURL)
        }
    }

    private static func waitForRegistration(imageURL: URL) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 16
        var stability = SystemWallpaperStabilityGate()
        while true {
            try Task.checkCancellation()
            let matches = registrationMatches(imageURL)
            let observedAt = ProcessInfo.processInfo.systemUptime
            if observedAt <= deadline, stability.observe(matches: matches, at: observedAt) { return }
            guard observedAt < deadline else { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw BackendError.message("系统尚未稳定登记场景静帧，正在恢复原壁纸")
    }

    private static func systemStateMatches(_ imageURL: URL) -> Bool {
        guard let document = wallpaperDocument(),
              let spaces = document["Spaces"] as? [String: Any], spaces.isEmpty,
              let all = document["AllSpacesAndDisplays"] as? [String: Any],
              all["Type"] as? String == "individual" else { return false }
        return imageMatches(all["Desktop"], imageURL)
    }

    private static func setAllSpacesOn(imageURL: URL) async throws {
        // Navigation and the switch action may consume most of the first
        // deadline. Give the system a separate confirmation window after the
        // press, and do not require Settings to keep showing the same pane.
        let discoveryDeadline = ProcessInfo.processInfo.systemUptime + 20
        while ProcessInfo.processInfo.systemUptime < discoveryDeadline {
            try Task.checkCancellation()
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first {
                if let control = allSpacesSwitch(in: app), let value = switchValue(control) {
                    guard value == false else {
                        throw BackendError.message("系统墙纸开关未因登记静帧而关闭，拒绝重复切换")
                    }
                    guard AXUIElementPerformAction(control, kAXPressAction as CFString) == .success else {
                        throw BackendError.message("无法操作系统墙纸的全空间开关")
                    }
                    try await waitForSystemState(imageURL: imageURL)
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw BackendError.message("无法定位系统墙纸的全空间开关，正在恢复原壁纸")
    }

    private static func waitForSystemState(imageURL: URL) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 18
        var stability = SystemWallpaperStabilityGate()
        while true {
            try Task.checkCancellation()
            let matches = systemStateMatches(imageURL)
            let observedAt = ProcessInfo.processInfo.systemUptime
            if observedAt <= deadline, stability.observe(matches: matches, at: observedAt) { return }
            guard observedAt < deadline else { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw BackendError.message("系统全空间底图未持续稳定，正在恢复原壁纸")
    }
}
