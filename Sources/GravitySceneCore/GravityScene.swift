import Foundation

/// Declarative, fixed presets only. This format cannot load executable code or shaders.
public struct GravityScene: Codable, Sendable {
    public static let format = "wallpaperui.gravity.v1"
    public let format: String
    public let preset: Preset
    public enum Preset: String, Codable, Sendable {
        case ultra, efficient
        public var width: Int { self == .ultra ? 2560 : 1600 }
        public var fps: Int { 30 }
        public var steps: Int { self == .ultra ? 150 : 90 }
        public var title: String { self == .ultra ? "引力之旅 · 极致画质" : "引力之旅 · 性能优先" }
    }
    public static func load(_ url: URL) throws -> GravityScene? {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, (1...4096).contains(size) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= 4096, data.first == 123 else { return nil }
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        guard manifest.format == Self.format else { return nil }
        return manifest
    }
}
