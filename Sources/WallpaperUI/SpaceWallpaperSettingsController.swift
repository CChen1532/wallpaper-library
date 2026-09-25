import AppKit
import ApplicationServices
import Foundation

/// Drives only the macOS Wallpaper pane's identified all-Spaces switch.
/// Its action (unlike editing Index.plist alone) updates Mission Control's
/// thumbnails on the tested macOS 15 build. Accessibility permission is
/// required once for the signed WallpaperUI app.
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
        for key in [kAXWindowsAttribute as String, kAXChildrenAttribute as String, "AXContents"] {
            guard let children = attribute(element, key) as? [AXUIElement] else { continue }
            for child in children {
                if let found = findSwitch(child, remaining: &remaining) { return found }
            }
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

    private static func systemStateMatches(_ imageURL: URL) -> Bool {
        let store = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        guard let data = try? Data(contentsOf: store),
              let document = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let spaces = document["Spaces"] as? [String: Any], spaces.isEmpty,
              let all = document["AllSpacesAndDisplays"] as? [String: Any],
              all["Type"] as? String == "individual",
              let desktop = all["Desktop"] as? [String: Any],
              let content = desktop["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]], choices.count == 1,
              let files = choices[0]["Files"] as? [[String: String]], files.count == 1,
              let relative = files[0]["relative"], let url = URL(string: relative) else { return false }
        return url.standardizedFileURL == imageURL.standardizedFileURL
    }

    private static func setAllSpacesOn(imageURL: URL) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        var pressed = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first {
                let root = AXUIElementCreateApplication(app.processIdentifier)
                var remaining = 4000
                if let control = findSwitch(root, remaining: &remaining), let value = switchValue(control) {
                    if !pressed {
                        guard value == false else {
                            throw BackendError.message("系统墙纸开关未因登记静帧而关闭，拒绝重复切换")
                        }
                        guard AXUIElementPerformAction(control, kAXPressAction as CFString) == .success else {
                            throw BackendError.message("无法操作系统墙纸的全空间开关")
                        }
                        pressed = true
                    } else if value && systemStateMatches(imageURL) {
                        return
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw BackendError.message("系统没有确认全空间底图，正在恢复原壁纸")
    }
}
