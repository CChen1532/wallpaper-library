import Foundation
import CryptoKit

enum SceneScriptStorage {
    static func prepare(package: URL, root: URL? = nil, legacy: URL? = nil) throws -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = root ?? support.appendingPathComponent("WallpaperUI/SceneStorage", isDirectory: true)
        let identity = package.standardizedFileURL.resolvingSymlinksInPath().path
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = directory.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = package.deletingLastPathComponent().lastPathComponent + ".json"
        let target = folder.appendingPathComponent(name)
        let previous = legacy ?? (root == nil ? support.appendingPathComponent("Mirage/SceneStorage/" + name) : nil)
        if !FileManager.default.fileExists(atPath: target.path), let previous,
           let values = try? previous.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
           values.isRegularFile == true, values.isSymbolicLink != true,
           (values.fileSize ?? Int.max) <= 1_048_576,
           let data = try? Data(contentsOf: previous),
           (try? JSONSerialization.jsonObject(with: data)) is [String: String] {
            try data.write(to: target, options: .atomic)
        }
        return folder
    }
}
