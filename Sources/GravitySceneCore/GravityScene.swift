import Foundation

/// Declarative, fixed presets only. This format cannot load executable code or shaders.
public struct GravityScene: Codable, Sendable {
    public static let format = "wallpaperui.gravity.v1"
    public let format: String
    public let preset: Preset
    public enum Preset: String, Codable, Sendable {
        case ultra, efficient
        public var width: Int { self == .ultra ? 3840 : 1600 }
        /// Ultra renders at 4K even on a smaller panel, then downsamples for
        /// cleaner formulas. Preserve aspect ratio and bound portrait textures.
        public func renderSize(width: Double, height: Double) -> (width: Int, height: Int) {
            guard width.isFinite, height.isFinite, width > 0, height > 0 else {
                return self == .ultra ? (3840, 2160) : (1600, 900)
            }
            let scale = self == .ultra ? 3840 / max(width, height)
                                      : min(1, 1600 / width, 4096 / height)
            return (max(16, Int((width * scale).rounded())), max(16, Int((height * scale).rounded())))
        }
        public var fps: Int { self == .ultra ? 120 : 30 }
        public var steps: Int { self == .ultra ? 150 : 90 }
        public var title: String { self == .ultra ? "引力之旅 · 极致画质 4K" : "引力之旅 · 性能优先" }
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
