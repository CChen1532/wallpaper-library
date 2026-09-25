import Foundation

/// A validated snapshot: changing defaults never mutates a running session.
struct ScenePreferences: Equatable, Sendable {
    var fps = 30
    var cropMode = "auto"
    var mouseEnabled = true
    var mouseButtonsEnabled = true
    var inputHz = 60
    var followsDisplay = true
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
