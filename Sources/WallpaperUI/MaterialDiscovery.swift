import Foundation

enum MaterialRemoval {
    struct Request: Identifiable {
        let payload: URL
        let target: URL
        let stamp: String
        let title: String
        var id: String { target.path }
        init(payload: URL, title: String, roots: [URL]) throws {
            self.payload = payload; self.title = title
            target = try MaterialRemoval.target(for: payload, roots: roots)
            stamp = try MaterialDiscovery.stamp(payload)
        }
    }
    struct BatchResult {
        var removed: [URL] = []
        var failures: [String] = []
    }
    static func contains(_ parent: URL, _ child: URL) -> Bool {
        let a = parent.standardizedFileURL.resolvingSymlinksInPath().path
        let b = child.standardizedFileURL.resolvingSymlinksInPath().path
        return b == a || b.hasPrefix(a + "/")
    }
    static func isBundled(_ url: URL) -> Bool { contains(Bundle.main.bundleURL, url) }

    /// Capture this target before showing the confirmation, then validate it again before trashing.
    static func target(for payload: URL, roots: [URL]) throws -> URL {
        let url = payload.standardizedFileURL
        guard url == url.resolvingSymlinksInPath(), !isBundled(url),
              roots.contains(where: { contains($0, url) }),
              (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
            throw BackendError.message("无法删除此项目：文件已改变、位于资料库之外或属于内置素材。")
        }
        var target = url
        if url.lastPathComponent == "scene.pkg" { target = url.deletingLastPathComponent() }
        else if url.pathExtension.lowercased() == "mp4" {
            var parent = url.deletingLastPathComponent()
            while roots.contains(where: { contains($0, parent) }) {
                let json = parent.appendingPathComponent("project.json")
                if let size = try? json.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
                   let data = try? Data(contentsOf: json), let project = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   (project["type"] as? String)?.lowercased() == "video", let file = project["file"] as? String,
                   parent.appendingPathComponent(file).standardizedFileURL == url { target = parent; break }
                parent.deleteLastPathComponent()
            }
        } else { throw BackendError.message("请选择场景或 MP4 视频。") }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let protected = [URL(fileURLWithPath: "/"), home, home.appendingPathComponent("Desktop"), home.appendingPathComponent("Documents"), home.appendingPathComponent("Library")]
        guard !protected.contains(where: { $0.path == target.path }), !roots.contains(where: { $0.path != target.path && contains(target, $0) }) else {
            throw BackendError.message("此文件夹包含其他素材来源，请先在设置中移除来源。")
        }
        return target
    }
}

/// Shared discovery rules for the UI and the existing video backend.
enum MaterialDiscovery {
    struct Candidate: Equatable, Sendable {
        enum Kind: Sendable { case scene, video }
        let url: URL
        let kind: Kind
        let stamp: String
        var title: String? = nil
    }
    static func roots(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                      defaults: UserDefaults = .standard) -> [URL] {
        var paths = [home.appendingPathComponent("Movies/Wallpapers").path,
                     home.appendingPathComponent("Movies/Wallpapers2").path]
        if let old = defaults.string(forKey: "sceneLibraryPath"), !old.isEmpty { paths.append(old) }
        paths += defaults.stringArray(forKey: "materialLibraryPaths") ?? []
        let excluded = Set((defaults.stringArray(forKey: "removedMaterialLibraryPaths") ?? []).map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path })
        var seen = Set<String>()
        return paths.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
            .filter { !excluded.contains($0.path) && seen.insert($0.path).inserted }
    }
    static func setIncluded(_ included: Bool, folder: URL, defaults: UserDefaults = .standard) {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        var paths = Set(defaults.stringArray(forKey: "materialLibraryPaths") ?? [])
        var excluded = Set(defaults.stringArray(forKey: "removedMaterialLibraryPaths") ?? [])
        if included { paths.insert(path); excluded.remove(path) }
        else { paths.remove(path); excluded.insert(path) }
        defaults.set(paths.sorted(), forKey: "materialLibraryPaths")
        defaults.set(excluded.sorted(), forKey: "removedMaterialLibraryPaths")
    }
    static func stamp(_ url: URL) throws -> String {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == .typeRegular else { throw BackendError.message("素材不是普通文件") }
        return "\(a[.size] ?? 0)|\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(a[.systemFileNumber] ?? 0)"
    }
    private static func displayTitle(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let clean = raw.components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : String(clean.prefix(160))
    }
    static func scan(_ root: URL) throws -> [Candidate] {
        let fm = FileManager.default
        var results: [Candidate] = []; var visited = 0
        func walk(_ folder: URL, _ depth: Int) throws {
            try Task.checkCancellation()
            let attributes = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { return }
            let pkg = folder.appendingPathComponent("scene.pkg")
            if let signature = try? stamp(pkg) {
                let metadata = (try? stamp(folder.appendingPathComponent("project.json"))) ?? ""
                results.append(.init(url: pkg.standardizedFileURL, kind: .scene, stamp: signature + metadata))
                return // Only a regular scene package owns its accompanying assets and preview.
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
                        results.append(.init(url: url.standardizedFileURL, kind: .video, stamp: signature, title: displayTitle(project["title"])))
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
