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

enum SystemWallpaperActivationAction: Equatable { case wait, press, complete }

/// WallpaperAgent can undo the first Settings press while it finishes a
/// desktop-image registration. Retry only after the switch is visibly off and
/// the all-Spaces selection has gone away; never toggle a switch that is on.
struct SystemWallpaperActivationGate {
    static let retryInterval: TimeInterval = 2
    static let maximumPresses = 3

    private var stability = SystemWallpaperStabilityGate()
    private(set) var pressCount = 0
    private var previousPress: TimeInterval?

    mutating func observe(matches: Bool, switchIsOn: Bool?, at uptime: TimeInterval) -> SystemWallpaperActivationAction {
        let canConfirm = pressCount > 0 || switchIsOn == true
        if stability.observe(matches: canConfirm && matches, at: uptime) { return .complete }
        guard switchIsOn == false, !matches, pressCount < Self.maximumPresses else { return .wait }
        if let previousPress, uptime - previousPress < Self.retryInterval { return .wait }
        pressCount += 1
        previousPress = uptime
        return .press
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
            throw BackendError.message("系统未登记当前壁纸静帧，自动底图已取消")
        }
        // setDesktopImageURL returns before WallpaperAgent has rebuilt its
        // per-Space selections. Pressing the Settings switch during that
        // rewrite can be undone by the later registration write.
        try await waitForRegistration(imageURL: imageURL)
        if allSpacesSwitch() == nil {
            guard let pane = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") else {
                throw BackendError.message("无法定位系统墙纸设置，自动底图已取消")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.open(pane, configuration: configuration) { _, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
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
        if attribute(element, "AXIdentifier") as? String == "ShowOnAllDisplays",
           switchValue(element) != nil { return element }
        let label = (attribute(element, kAXTitleAttribute as String) as? String)
            ?? (attribute(element, kAXDescriptionAttribute as String) as? String)
        if (label == "在所有空间中显示" || label == "Show on All Spaces"),
           switchValue(element) != nil { return element }
        for key in [kAXChildrenAttribute as String, "AXContents"] {
            guard let children = attribute(element, key) as? [AXUIElement] else { continue }
            for child in children {
                if let found = findSwitch(child, remaining: &remaining) { return found }
            }
        }
        return nil
    }

    private static func allSpacesSwitch() -> AXUIElement? {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences") {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            var roots: [AXUIElement] = []
            for key in [kAXMainWindowAttribute as String, kAXFocusedWindowAttribute as String] {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(root, key as CFString, &value) == .success,
                   let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                    roots.append(value as! AXUIElement)
                }
            }
            if let windows = attribute(root, kAXWindowsAttribute as String) as? [AXUIElement] {
                roots.append(contentsOf: windows)
            }
            roots.append(root)
            for element in roots {
                var remaining = 8000
                if let control = findSwitch(element, remaining: &remaining), switchValue(control) != nil {
                    return control
                }
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
        // The first press sometimes survives for less than a second before a
        // delayed WallpaperAgent write puts the per-Space selection back.
        // Confirmation must be stable, and a reverted switch may be pressed
        // again within a small, bounded number of attempts.
        let discoveryDeadline = ProcessInfo.processInfo.systemUptime + 20
        var confirmationDeadline: TimeInterval?
        var activation = SystemWallpaperActivationGate()
        while true {
            try Task.checkCancellation()
            let now = ProcessInfo.processInfo.systemUptime
            if let confirmationDeadline {
                guard now < confirmationDeadline else { break }
            } else if now >= discoveryDeadline {
                throw BackendError.message("无法定位系统墙纸的全空间开关，正在恢复原壁纸")
            }
            let control = allSpacesSwitch()
            let action = activation.observe(matches: systemStateMatches(imageURL),
                                            switchIsOn: control.flatMap(switchValue), at: now)
            switch action {
            case .complete:
                return
            case .press:
                if let control {
                    guard AXUIElementPerformAction(control, kAXPressAction as CFString) == .success else {
                        throw BackendError.message("无法操作系统墙纸的全空间开关")
                    }
                    if confirmationDeadline == nil { confirmationDeadline = now + 25 }
                }
            case .wait:
                if confirmationDeadline == nil, control.flatMap(switchValue) == true {
                    confirmationDeadline = now + 25
                }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw BackendError.message("系统全空间底图未持续稳定，正在恢复原壁纸")
    }
}
