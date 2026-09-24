import AppKit
import CoreGraphics

public struct FocusScreen: Equatable {
    public let displayID: UInt32
    public let bounds: CGRect

    public init(displayID: UInt32, bounds: CGRect) {
        self.displayID = displayID
        self.bounds = bounds
    }
}

public struct FocusWindow {
    public let ownerPID: Int32
    public let layer: Int
    public let alpha: Double
    public let bounds: CGRect

    public init(ownerPID: Int32, layer: Int, alpha: Double, bounds: CGRect) {
        self.ownerPID = ownerPID
        self.layer = layer
        self.alpha = alpha
        self.bounds = bounds
    }
}

public enum FocusDisplaySource: String {
    case frontmostWindow
    case cursorFallback
    case unknown
}

public struct FocusDisplaySelection {
    public let displayID: UInt32?
    public let source: FocusDisplaySource
}

/// Selects one display from the frontmost app's topmost ordinary window.
/// Cursor location is a permission-free fallback for Finder desktop focus and
/// apps whose windows are absent from the public WindowServer listing.
public enum FocusDisplaySelector {
    public static func choose(frontmostPID: Int32?, windows: [FocusWindow],
                              screens: [FocusScreen], cursorDisplayID: UInt32?) -> UInt32? {
        select(frontmostPID: frontmostPID, windows: windows, screens: screens,
               cursorDisplayID: cursorDisplayID).displayID
    }

    public static func select(frontmostPID: Int32?, windows: [FocusWindow],
                              screens: [FocusScreen], cursorDisplayID: UInt32?) -> FocusDisplaySelection {
        if let frontmostPID {
            for window in windows where window.ownerPID == frontmostPID &&
                                        window.layer == 0 && window.alpha > 0.01 &&
                                        window.bounds.width > 0 && window.bounds.height > 0 {
                let target = screens.map { screen in
                    (screen.displayID, window.bounds.intersection(screen.bounds))
                }.max { lhs, rhs in
                    (lhs.1.isNull ? 0 : lhs.1.width * lhs.1.height) <
                    (rhs.1.isNull ? 0 : rhs.1.width * rhs.1.height)
                }
                if let target, !target.1.isNull, target.1.width * target.1.height > 0 {
                    return FocusDisplaySelection(displayID: target.0, source: .frontmostWindow)
                }
            }
        }
        if screens.contains(where: { $0.displayID == cursorDisplayID }) {
            return FocusDisplaySelection(displayID: cursorDisplayID, source: .cursorFallback)
        }
        return FocusDisplaySelection(displayID: nil, source: .unknown)
    }

    public static func currentDisplay() -> UInt32? {
        currentSelection().displayID
    }

    public static func currentSelection() -> FocusDisplaySelection {
        let screens = NSScreen.screens.compactMap { screen -> FocusScreen? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber, number.uint32Value != 0 else { return nil }
            return FocusScreen(displayID: number.uint32Value,
                               bounds: CGDisplayBounds(number.uint32Value))
        }
        let mouse = NSEvent.mouseLocation
        let cursorID = NSScreen.screens.first(where: { NSPointInRect(mouse, $0.frame) })
            .flatMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
        let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] ?? []
        let windows: [FocusWindow] = listed.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = info[kCGWindowLayer as String] as? NSNumber,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? NSNumber, let y = bounds["Y"] as? NSNumber,
                  let width = bounds["Width"] as? NSNumber,
                  let height = bounds["Height"] as? NSNumber else { return nil }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            return FocusWindow(ownerPID: pid.int32Value, layer: layer.intValue, alpha: alpha,
                               bounds: CGRect(x: x.doubleValue, y: y.doubleValue,
                                              width: width.doubleValue, height: height.doubleValue))
        }
        let app = NSWorkspace.shared.frontmostApplication
        // Finder may be frontmost because the desktop was clicked while an old
        // Finder window remains visible elsewhere. Cursor screen is the safer
        // location for desktop focus in that case.
        let focusedPID = app?.bundleIdentifier == "com.apple.finder" ? nil : app?.processIdentifier
        return select(frontmostPID: focusedPID, windows: windows,
                      screens: screens, cursorDisplayID: cursorID)
    }
}

/// Two matching polls are required before moving the only renderer window.
public struct FocusDisplayDwell {
    public private(set) var currentDisplayID: UInt32
    private var pendingDisplayID: UInt32?
    private var pendingCount = 0

    public init(currentDisplayID: UInt32) { self.currentDisplayID = currentDisplayID }

    public mutating func observe(_ target: UInt32?) -> UInt32? {
        guard let target, target != currentDisplayID else {
            pendingDisplayID = nil
            pendingCount = 0
            return nil
        }
        if pendingDisplayID == target { pendingCount += 1 }
        else { pendingDisplayID = target; pendingCount = 1 }
        guard pendingCount >= 2 else { return nil }
        currentDisplayID = target
        pendingDisplayID = nil
        pendingCount = 0
        return target
    }
}
