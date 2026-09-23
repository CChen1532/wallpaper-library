import Foundation

struct WESceneCatalogEntry: Codable {
    let name: String
    let title: String?
    let packagePath: String
    let packageBytes: Int64
    let capability: WESceneCapabilityReport?
    let error: String?
}

struct WESceneCatalogReport: Codable {
    let schemaVersion: Int
    let root: String
    let desktopScenePlayable: Bool
    let entries: [WESceneCatalogEntry]
}

extension WESceneInspection {
    private static func sceneTitle(in folder: URL) -> String? {
        let project = folder.appendingPathComponent("project.json", isDirectory: false)
        guard let values = try? project.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, (1...1_048_576).contains(size),
              let data = try? Data(contentsOf: project, options: .mappedIfSafe),
              (1...1_048_576).contains(data.count),
              let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              metadata["type"] as? String == "scene",
              let raw = metadata["title"] as? String else { return nil }
        let clean = raw.components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        return String(clean.prefix(160))
    }

    /// One directory level only; no symlinks, writes, scripts, or desktop operations.
    public static func catalog(directory: URL, maxPreviewDimension: Int = 640) throws -> Data {
        guard (1...960).contains(maxPreviewDimension) else {
            throw ProbeError.invalid("场景目录预览最长边必须在1...960")
        }
        let fm = FileManager.default
        let rootValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw ProbeError.invalid("场景根目录必须是真实目录，不跟随符号链接")
        }
        let children = try fm.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        guard children.count <= 1000 else { throw ProbeError.invalid("场景根目录条目超过1000") }
        var packages: [(String, String?, URL, Int64)] = []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try Task.checkCancellation()
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let pkg = child.appendingPathComponent("scene.pkg", isDirectory: false)
            guard fm.fileExists(atPath: pkg.path) else { continue }
            let pkgValues = try pkg.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard pkgValues.isRegularFile == true, pkgValues.isSymbolicLink != true else { continue }
            let bytes = Int64(pkgValues.fileSize ?? -1)
            packages.append((child.lastPathComponent, sceneTitle(in: child), pkg, bytes))
        }
        guard packages.count <= 20 else { throw ProbeError.invalid("场景包数量超过20") }
        var entries: [WESceneCatalogEntry] = []
        for (name, title, pkg, bytes) in packages {
            try Task.checkCancellation()
            guard bytes > 0 && bytes <= 128 * 1024 * 1024 else {
                entries.append(.init(name: name, title: title, packagePath: pkg.path, packageBytes: bytes,
                                     capability: nil, error: "场景包大小不在1...128MiB范围"))
                continue
            }
            do {
                let data = try Data(contentsOf: pkg, options: .mappedIfSafe)
                guard data.count > 0 && data.count <= 128 * 1024 * 1024 else {
                    throw ProbeError.invalid("读取后的场景包大小超出1...128MiB范围")
                }
                let report = try capabilityReport(packageData: data, maxPreviewDimension: maxPreviewDimension)
                let capability = try JSONDecoder().decode(WESceneCapabilityReport.self, from: report)
                entries.append(.init(name: name, title: title, packagePath: pkg.path, packageBytes: bytes,
                                     capability: capability, error: nil))
            } catch is CancellationError { throw CancellationError() }
            catch {
                entries.append(.init(name: name, title: title, packagePath: pkg.path, packageBytes: bytes,
                                     capability: nil, error: String(describing: error)))
            }
        }
        let report = WESceneCatalogReport(schemaVersion: 1, root: directory.path,
                                          desktopScenePlayable: false, entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }
}
