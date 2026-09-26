import Foundation

/// Shared discovery rules for the UI and the existing video backend.
enum MaterialDiscovery {
    struct Candidate: Equatable, Sendable {
        enum Kind: Sendable { case scene, video }
        let url: URL
        let kind: Kind
        let stamp: String
    }
    static func roots(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                      defaults: UserDefaults = .standard) -> [URL] {
        var paths = [home.appendingPathComponent("Movies/Wallpapers").path,
                     home.appendingPathComponent("Movies/Wallpapers2").path]
        if let old = defaults.string(forKey: "sceneLibraryPath"), !old.isEmpty { paths.append(old) }
        paths += defaults.stringArray(forKey: "materialLibraryPaths") ?? []
        var seen = Set<String>()
        return paths.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
            .filter { seen.insert($0.path).inserted }
    }
    static func stamp(_ url: URL) throws -> String {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == .typeRegular else { throw BackendError.message("素材不是普通文件") }
        return "\(a[.size] ?? 0)|\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(a[.systemFileNumber] ?? 0)"
    }
    static func scan(_ root: URL) throws -> [Candidate] {
        let fm = FileManager.default
        var results: [Candidate] = []; var visited = 0
        func walk(_ folder: URL, _ depth: Int) throws {
            try Task.checkCancellation()
            let attributes = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { return }
            let pkg = folder.appendingPathComponent("scene.pkg")
            if fm.fileExists(atPath: pkg.path) {
                if let signature = try? stamp(pkg) {
                    let metadata = (try? stamp(folder.appendingPathComponent("project.json"))) ?? ""
                    results.append(.init(url: pkg.standardizedFileURL, kind: .scene, stamp: signature + metadata))
                }
                return // Scene assets and preview.mp4 are never separate wallpapers.
            }
            guard depth <= 8 else { return }
            let children = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            // WE video projects designate one video; ignore their animated preview.
            if let size = try? fm.attributesOfItem(atPath: folder.appendingPathComponent("project.json").path)[.size] as? NSNumber, size.intValue <= 1_048_576,
               let data = try? Data(contentsOf: folder.appendingPathComponent("project.json")), data.count <= 1_048_576,
               let project = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let type = project["type"] as? String {
                if type.lowercased() == "video", let file = project["file"] as? String {
                    let url = folder.appendingPathComponent(file).standardizedFileURL
                    if url.path.hasPrefix(folder.standardizedFileURL.path + "/"),
                       url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL, url.pathExtension.lowercased() == "mp4",
                       let signature = try? stamp(url) {
                        results.append(.init(url: url.standardizedFileURL, kind: .video, stamp: signature))
                    }
                    return
                }
                if ["scene", "web", "application"].contains(type.lowercased()) { return }
            }
            if fm.fileExists(atPath: folder.appendingPathComponent("project.json").path) { return } // Incomplete/unsupported project: retry later.
            for child in children.sorted(by: { $0.path < $1.path }) {
                visited += 1
                guard visited <= 20_000 else { throw BackendError.message("素材目录超过20000项，请选择更具体的目录") }
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { continue }
                guard values.isSymbolicLink != true else { continue }
                if values.isDirectory == true { try walk(child, depth + 1) }
                else if child.pathExtension.lowercased() == "mp4", let signature = try? stamp(child) {
                    results.append(.init(url: child.standardizedFileURL, kind: .video, stamp: signature))
                }
            }
        }
        try walk(root.standardizedFileURL, 0)
        return results
    }
}

actor VideoLibraryCache {
    static let shared = VideoLibraryCache()
    private var values: [String: (String, Wallpaper)] = [:]
    func get(_ url: URL, stamp: String) -> Wallpaper? {
        guard let value = values[url.path], value.0 == stamp, let thumbnail = value.1.thumbnail,
              let attributes = try? FileManager.default.attributesOfItem(atPath: thumbnail.path),
              (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0 else { return nil }
        return value.1
    }
    func save(_ item: Wallpaper, stamp: String) {
        if values.count > 2048 { values.removeAll() }
        if item.playable && item.warning == nil { values[item.id] = (stamp, item) }
    }
}
