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

    var volume = 1.0
    var speed = 1.0
    var fillMode = "cover"
    var positionX = 0.5
    var positionY = 0.5
    var renderScale = 1.0
    var metalFX = false
    var msaa = 1
    var energySaving = false
    var pauseWhenCovered = false
    var mediaInfoEnabled = false
    var shortcutsEnabled = false

    init(fps: Int = 30,
         cropMode: String = "auto",
         mouseEnabled: Bool = true,
         mouseButtonsEnabled: Bool = true,
         inputHz: Int = 60,
         followsDisplay: Bool = true,
         displayUUID: String? = nil,
         displayName: String? = nil,
         soundEnabled: Bool = false,
         audioResponseEnabled: Bool = false,
         volume: Double = 1.0,
         speed: Double = 1.0,
         fillMode: String = "cover",
         positionX: Double = 0.5,
         positionY: Double = 0.5,
         renderScale: Double = 1.0,
         metalFX: Bool = false,
         msaa: Int = 1,
         energySaving: Bool = false,
         pauseWhenCovered: Bool = false,
         mediaInfoEnabled: Bool = false,
         shortcutsEnabled: Bool = false) {
        self.fps = fps
        self.cropMode = cropMode
        self.mouseEnabled = mouseEnabled
        self.mouseButtonsEnabled = mouseButtonsEnabled
        self.inputHz = inputHz
        self.followsDisplay = followsDisplay
        self.displayUUID = displayUUID
        self.displayName = displayName
        self.soundEnabled = soundEnabled
        self.audioResponseEnabled = audioResponseEnabled
        self.volume = volume
        self.speed = speed
        self.fillMode = fillMode
        self.positionX = positionX
        self.positionY = positionY
        self.renderScale = renderScale
        self.metalFX = metalFX
        self.msaa = msaa
        self.energySaving = energySaving
        self.pauseWhenCovered = pauseWhenCovered
        self.mediaInfoEnabled = mediaInfoEnabled
        self.shortcutsEnabled = shortcutsEnabled
    }
    enum CodingKeys: String, CodingKey {
        case fps, cropMode, mouseEnabled, mouseButtonsEnabled, inputHz, followsDisplay, soundEnabled, audioResponseEnabled, volume, speed, fillMode, positionX, positionY, renderScale, metalFX, msaa, energySaving, pauseWhenCovered, mediaInfoEnabled, shortcutsEnabled, displayUUID, displayName
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fps = (try? c.decode(Int.self, forKey: .fps)) ?? 30
        cropMode = (try? c.decode(String.self, forKey: .cropMode)) ?? "auto"
        mouseEnabled = (try? c.decode(Bool.self, forKey: .mouseEnabled)) ?? true
        mouseButtonsEnabled = (try? c.decode(Bool.self, forKey: .mouseButtonsEnabled)) ?? true
        inputHz = (try? c.decode(Int.self, forKey: .inputHz)) ?? 60
        followsDisplay = (try? c.decode(Bool.self, forKey: .followsDisplay)) ?? true
        soundEnabled = (try? c.decode(Bool.self, forKey: .soundEnabled)) ?? false
        audioResponseEnabled = (try? c.decode(Bool.self, forKey: .audioResponseEnabled)) ?? false
        volume = (try? c.decode(Double.self, forKey: .volume)) ?? 1.0
        speed = (try? c.decode(Double.self, forKey: .speed)) ?? 1.0
        fillMode = (try? c.decode(String.self, forKey: .fillMode)) ?? "cover"
        positionX = (try? c.decode(Double.self, forKey: .positionX)) ?? 0.5
        positionY = (try? c.decode(Double.self, forKey: .positionY)) ?? 0.5
        renderScale = (try? c.decode(Double.self, forKey: .renderScale)) ?? 1.0
        metalFX = (try? c.decode(Bool.self, forKey: .metalFX)) ?? false
        msaa = (try? c.decode(Int.self, forKey: .msaa)) ?? 1
        energySaving = (try? c.decode(Bool.self, forKey: .energySaving)) ?? false
        pauseWhenCovered = (try? c.decode(Bool.self, forKey: .pauseWhenCovered)) ?? false
        mediaInfoEnabled = (try? c.decode(Bool.self, forKey: .mediaInfoEnabled)) ?? false
        shortcutsEnabled = (try? c.decode(Bool.self, forKey: .shortcutsEnabled)) ?? false
        displayUUID = try? c.decode(String.self, forKey: .displayUUID)
        displayName = try? c.decode(String.self, forKey: .displayName)
    }

    func canUpdateLive(from old: Self) -> Bool {
        mouseEnabled == old.mouseEnabled && mouseButtonsEnabled == old.mouseButtonsEnabled &&
        inputHz == old.inputHz && audioResponseEnabled == old.audioResponseEnabled &&
        followsDisplay == old.followsDisplay && displayUUID == old.displayUUID &&
        renderScale == old.renderScale && metalFX == old.metalFX && msaa == old.msaa
    }

    func position(for package: URL) -> (Double, Double) {
        let x: Double
        switch cropMode {
        case "left": x = 0
        case "right": x = 1
        case "custom": x = positionX
        case "auto": x = package.deletingLastPathComponent().lastPathComponent == "1000000001" ? 1 : 0.5
        default: x = 0.5
        }
        return (x, positionY)
    }

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
        if [15, 30, 60, 120].contains(fps) { value.fps = fps }
        if let crop = defaults.string(forKey: Key.crop), ["auto", "center", "left", "right", "custom"].contains(crop) { value.cropMode = crop }
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

    static func normalized(_ preferences: ScenePreferences) -> ScenePreferences {
        var value = preferences
        if ![15, 30, 60, 120].contains(value.fps) { value.fps = 30 }
        if ![30, 60, 120].contains(value.inputHz) { value.inputHz = 60 }
        if !["auto", "center", "left", "right", "custom"].contains(value.cropMode) { value.cropMode = "auto" }
        func finite(_ n: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
            n.isFinite ? min(range.upperBound, max(range.lowerBound, n)) : fallback
        }
        value.volume = finite(value.volume, 0...1, fallback: 1)
        value.speed = finite(value.speed, 0.25...2, fallback: 1)
        value.positionX = finite(value.positionX, 0...1, fallback: 0.5)
        value.positionY = finite(value.positionY, 0...1, fallback: 0.5)
        value.renderScale = finite(value.renderScale, 0.25...1, fallback: 1)
        if !["cover", "contain", "stretch"].contains(value.fillMode) { value.fillMode = "cover" }
        if ![1, 2, 4, 8].contains(value.msaa) { value.msaa = 1 }
        if let stored = value.displayUUID {
            value.displayUUID = UUID(uuidString: stored)?.uuidString
            if value.displayUUID == nil { value.displayName = nil }
        }
        return value
    }
}
