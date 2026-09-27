import Foundation
import Combine
import AppKit

struct SceneDisplay: Identifiable, Hashable, Sendable {
    let id: UInt32
    let uuid: String
    let name: String

    @MainActor static func connected() -> [Self] {
        NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
            return Self(id: id, uuid: CFUUIDCreateString(nil, uuid) as String, name: screen.localizedName)
        }
    }

    /// Persist UUIDs, not transient display IDs. A disconnected fixed screen
    /// falls back without erasing the choice, and is selected on reconnection.
    static func resolve(_ preferences: ScenePreferences, displays: [Self], focus: UInt32?, current: UInt32? = nil) -> UInt32? {
        let ids = Set(displays.map(\.id))
        let focused = focus.flatMap { ids.contains($0) ? $0 : nil }
        let existing = current.flatMap { ids.contains($0) ? $0 : nil }
        if preferences.followsDisplay { return focused ?? existing ?? displays.first?.id }
        if let uuid = preferences.displayUUID,
           let fixed = displays.first(where: { $0.uuid == uuid }) { return fixed.id }
        return existing ?? focused ?? displays.first?.id
    }
}

/// A validated snapshot: changing defaults never mutates a running session.
struct ScenePreferences: Codable, Hashable, Sendable {
    var fps = 30
    var cropMode = "auto"
    var mouseEnabled = true
    var mouseButtonsEnabled = true
    var inputHz = 60
    var followsDisplay = true
    var displayUUID: String?
    var displayName: String?
    var soundEnabled = false
    var audioResponseEnabled = false

    enum Key {
        static let fps = "sceneFPS"
        static let crop = "sceneCropMode"
        static let mouse = "sceneMouseEnabled"
        static let buttons = "sceneMouseButtonsEnabled"
        static let inputHz = "sceneInputHz"
        static let followsDisplay = "sceneFollowsDisplay"
        static let sound = "sceneSoundEnabled"
        static let audioResponse = "sceneAudioResponseEnabled"
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        var value = Self()
        let fps = defaults.integer(forKey: Key.fps)
        if [30, 60].contains(fps) { value.fps = fps }
        if let crop = defaults.string(forKey: Key.crop), ["auto", "center", "left", "right"].contains(crop) { value.cropMode = crop }
        let hz = defaults.integer(forKey: Key.inputHz)
        if [30, 60, 120].contains(hz) { value.inputHz = hz }
        func flag(_ key: String, fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        value.mouseEnabled = flag(Key.mouse, fallback: true)
        value.mouseButtonsEnabled = flag(Key.buttons, fallback: true)
        value.followsDisplay = flag(Key.followsDisplay, fallback: true)
        value.soundEnabled = flag(Key.sound, fallback: false)
        value.audioResponseEnabled = flag(Key.audioResponse, fallback: false)
        return value
    }
}

/// Preferences are keyed by package location, never by title or current selection.
/// Old global values are frozen once for migration, then cease to be live defaults.
@MainActor final class ScenePreferencesStore: ObservableObject {
    static let migrationKey = "scenePreferences.v1.initialValues"
    private let defaults: UserDefaults
    private let initialValues: ScenePreferences

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.migrationKey) {
            initialValues = Self.decode(data) ?? .init()
        } else {
            let legacy = ScenePreferences.load(from: defaults)
            initialValues = legacy
            if let data = try? JSONEncoder().encode(legacy) {
                defaults.set(data, forKey: Self.migrationKey)
            }
        }
    }

    static func identity(for package: URL) -> String {
        package.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func storageKey(for package: URL) -> String {
        "scenePreferences.v1.item." + identity(for: package)
    }

    func preferences(for package: URL) -> ScenePreferences {
        guard let data = defaults.data(forKey: Self.storageKey(for: package)) else { return initialValues }
        return Self.decode(data) ?? initialValues
    }

    func save(_ preferences: ScenePreferences, for package: URL) {
        guard let data = try? JSONEncoder().encode(Self.normalized(preferences)) else { return }
        objectWillChange.send()
        defaults.set(data, forKey: Self.storageKey(for: package))
    }

    private static func decode(_ data: Data) -> ScenePreferences? {
        (try? JSONDecoder().decode(ScenePreferences.self, from: data)).map(normalized)
    }

    private static func normalized(_ preferences: ScenePreferences) -> ScenePreferences {
        var value = preferences
        if ![30, 60].contains(value.fps) { value.fps = 30 }
        if ![30, 60, 120].contains(value.inputHz) { value.inputHz = 60 }
        if !["auto", "center", "left", "right"].contains(value.cropMode) { value.cropMode = "auto" }
        if let stored = value.displayUUID {
            value.displayUUID = UUID(uuidString: stored)?.uuidString
            if value.displayUUID == nil { value.displayName = nil }
        }
        return value
    }
}
