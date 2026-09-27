import Foundation

/// A fixed bundled renderer; the scene manifest never supplies executable HTML or scripts.
public struct MoonScene: Codable, Sendable {
    public static let format = "wallpaperui.moon.v1"
    public let format: String
    public let preset: String
    public static func load(_ url: URL) throws -> MoonScene? {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, (1...4096).contains(size) else { return nil }
        let data = try Data(contentsOf: url)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["format"] as? String == Self.format else { return nil }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.preset == "selene" else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }
}
