import Foundation
import Combine

struct RotationWallpaper: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case scene, video }
    let id: String
    let path: String
    let title: String
    let kind: Kind
    let expectedBytes: Int64
    var url: URL { URL(fileURLWithPath: path) }

    init(url: URL, title: String, kind: Kind, expectedBytes: Int64 = 0) {
        id = LibraryCollectionStore.identity(url)
        path = url.standardizedFileURL.path
        self.title = title; self.kind = kind; self.expectedBytes = expectedBytes
    }
}

/// App metadata only: hiding never moves a material or changes its project file.
@MainActor final class LibraryCollectionStore: ObservableObject {
    private struct Snapshot: Codable {
        var hidden: Set<String> = []
        var rotation: [RotationWallpaper] = []
        var interval = 3600
        var mode = "rand"
    }
    static let storageKey = "libraryCollection.v1"
    private let defaults: UserDefaults
    @Published private var snapshot: Snapshot
    var hiddenIDs: Set<String> { snapshot.hidden }
    var rotationItems: [RotationWallpaper] { snapshot.rotation }
    var rotationCandidates: [RotationWallpaper] { snapshot.rotation.filter { !snapshot.hidden.contains($0.id) } }
    var interval: Int { snapshot.interval }
    var mode: String { snapshot.mode }

    nonisolated static func identity(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        // Foundation can leave aliases unresolved once the final file disappears.
        // Keep the metadata key stable while removable sources are unavailable.
        for prefix in ["/var", "/tmp"] where path == prefix || path.hasPrefix(prefix + "/") {
            return "/private" + path
        }
        return path
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var saved = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } ?? Snapshot()
        saved.interval = min(86400, max(60, saved.interval))
        if !["rand", "next"].contains(saved.mode) { saved.mode = "rand" }
        var seen = Set<String>()
        saved.rotation = saved.rotation.filter { $0.id.hasPrefix("/") && seen.insert($0.id).inserted }
        snapshot = saved
    }
    private func commit(_ value: Snapshot) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.storageKey)
        snapshot = value
    }
    func setHidden(_ hidden: Bool, ids: Set<String>) {
        guard !ids.isEmpty else { return }
        var next = snapshot
        if hidden { next.hidden.formUnion(ids) } else { next.hidden.subtract(ids) }
        guard next.hidden != snapshot.hidden else { return }
        commit(next)
    }
    @discardableResult func addToRotation(_ items: [RotationWallpaper]) -> Int {
        var next = snapshot
        var seen = Set(next.rotation.map(\.id))
        var added = 0
        for item in items {
            if seen.insert(item.id).inserted { next.rotation.append(item); added += 1 }
            else if let index = next.rotation.firstIndex(where: { $0.id == item.id }) { next.rotation[index] = item }
        }
        if next.rotation != snapshot.rotation { commit(next) }
        return added
    }
    func removeFromRotation(ids: Set<String>) {
        var next = snapshot; next.rotation.removeAll { ids.contains($0.id) }
        if next.rotation != snapshot.rotation { commit(next) }
    }
    func moveInRotation(_ id: String, offset: Int) {
        guard let from = snapshot.rotation.firstIndex(where: { $0.id == id }) else { return }
        let to = from + offset
        guard snapshot.rotation.indices.contains(to) else { return }
        var next = snapshot; next.rotation.swapAt(from, to); commit(next)
    }
    func configureRotation(interval: Int, mode: String) {
        guard (60...86400).contains(interval), ["rand", "next"].contains(mode) else { return }
        var next = snapshot; next.interval = interval; next.mode = mode; commit(next)
    }
    func forgetRemovedTargets(_ targets: [URL]) {
        let paths = targets.map(Self.identity)
        func removed(_ id: String) -> Bool { paths.contains { id == $0 || id.hasPrefix($0 + "/") } }
        var next = snapshot
        next.hidden = next.hidden.filter { !removed($0) }
        next.rotation.removeAll { removed($0.id) }
        commit(next)
    }
}

struct GalleryBatchSelection {
    var ids: Set<String> = []
    private var anchor: String?
    mutating func clear() { ids = []; anchor = nil }
    mutating func selectAll(_ visible: [String]) { ids = Set(visible); anchor = visible.first }
    mutating func retain(_ visible: [String]) {
        let allowed = Set(visible); ids.formIntersection(allowed)
        if let anchor, !allowed.contains(anchor) { self.anchor = nil }
    }
    mutating func toggle(_ id: String, visible: [String], extend: Bool = false) {
        guard let target = visible.firstIndex(of: id) else { return }
        if extend, let anchor, let start = visible.firstIndex(of: anchor) {
            ids.formUnion(visible[min(start, target)...max(start, target)])
        } else {
            if !ids.insert(id).inserted { ids.remove(id) }
            anchor = id
        }
    }
}
