import Foundation
import Combine
import WESceneCore

struct SceneCatalogPayload: Decodable {
    struct Entry: Decodable, Identifiable {
        struct Capability: Decodable {
            let resourceInspectionAvailable: Bool
            let restrictedStaticPreviewAvailable: Bool
            let desktopScenePlayable: Bool
            let limitationCodes: [String]
        }
        let name: String
        let title: String?
        let packagePath: String
        let packageBytes: Int64
        let capability: Capability?
        let error: String?
        // Supplied by the background scan; it reloads settings without changing card identity.
        var propertyMetadataStamp: String?
        var propertyCatalogRevision: String { id + "|" + (propertyMetadataStamp ?? "") }
        var id: String { URL(fileURLWithPath: packagePath).standardizedFileURL.path }
        var folder: URL { URL(fileURLWithPath: packagePath).deletingLastPathComponent() }
        var root: URL { folder.deletingLastPathComponent() }
    }
    let entries: [Entry]
}

@MainActor final class UnifiedLibrary: ObservableObject {
    @Published private(set) var scenes: [SceneCatalogPayload.Entry] = []
    @Published private(set) var scanning = false
    @Published private(set) var lastScan: Date?
    @Published private(set) var issues: [String] = []
    @Published private(set) var roots: [URL] = []
    private var cached: [String: (String, SceneCatalogPayload.Entry)] = [:]
    private var loop: Task<Void, Never>?
    private var rescanRequested = false
    private let model: LibraryModel
    private let rootProvider: () -> [URL]
    private let interval: Duration
    private let defaults: UserDefaults
    init(model: LibraryModel, interval: Duration = .seconds(60), roots: (() -> [URL])? = nil, defaults: UserDefaults = .standard) {
        self.model = model; self.interval = interval
        self.defaults = defaults
        self.rootProvider = roots ?? {
            var result = MaterialDiscovery.roots(defaults: defaults)
            if let bundled = Bundle.main.resourceURL?.appendingPathComponent("GravityScenes"),
               FileManager.default.fileExists(atPath: bundled.path), !result.contains(bundled) { result.append(bundled) }
            return result
        }
        updateRoots()
    }

    private func updateRoots() {
        roots = rootProvider()
    }

    func addFolder(_ url: URL) {
        MaterialDiscovery.setIncluded(true, folder: url, defaults: defaults)
        updateRoots()
        Task { await refresh() }
    }
    func removeFolder(_ url: URL) async {
        guard roots.contains(where: { $0.path == url.path }), !MaterialRemoval.isBundled(url),
              await model.prepareMaterialRemoval(url) else { return }
        MaterialDiscovery.setIncluded(false, folder: url, defaults: defaults)
        updateRoots()
        await refresh()
    }
    func didTrash(_ target: URL) async {
        cached = cached.filter { !MaterialRemoval.contains(target, URL(fileURLWithPath: $0.key)) }
        scenes.removeAll { MaterialRemoval.contains(target, URL(fileURLWithPath: $0.packagePath)) }
        if roots.contains(where: { $0.path == target.path }) { MaterialDiscovery.setIncluded(false, folder: target, defaults: defaults); updateRoots() }
        await refresh()
    }
    func start() {
        guard loop == nil else { return }
        let interval = interval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let started = ContinuousClock.now
                await self?.refresh()
                let elapsed = started.duration(to: .now)
                do { try await Task.sleep(for: max(.seconds(1), interval - elapsed)) } catch { break }
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil }

    func refresh() async {
        guard !scanning else { rescanRequested = true; return }
        scanning = true
        defer { scanning = false }
        repeat {
            rescanRequested = false
            updateRoots()
            let currentRoots = roots
            let old = cached
            let snapshot = await Task.detached(priority: .utility) {
                var found: [String: MaterialDiscovery.Candidate] = [:]
                var issues: [String] = []
                var failedRoots: [URL] = []
                for root in currentRoots {
                    do { for candidate in try MaterialDiscovery.scan(root) where candidate.kind == .scene {
                        found[candidate.url.path] = candidate
                    } } catch { issues.append(root.lastPathComponent + ": " + error.localizedDescription); failedRoots.append(root) }
                }
                return (found, issues, failedRoots)
            }.value
            guard !Task.isCancelled else { return }
            var next: [String: (String, SceneCatalogPayload.Entry)] = [:]
            var errors = snapshot.1
            // Two observations prevent publishing files actively being copied.
            if snapshot.0.contains(where: { old[$0.key]?.0 != $0.value.stamp }) {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            for (path, candidate) in snapshot.0.sorted(by: { $0.key < $1.key }) {
                guard !Task.isCancelled else { return }
                if let value = old[path], value.0 == candidate.stamp { next[path] = value; continue }
                let result = await Task.detached(priority: .utility) { () -> SceneCatalogPayload.Entry? in
                    let folder = candidate.url.deletingLastPathComponent()
                    let current = (try? MaterialDiscovery.stamp(candidate.url)) ?? ""
                    let meta = (try? MaterialDiscovery.stamp(folder.appendingPathComponent("project.json"))) ?? ""
                    guard current + meta == candidate.stamp else { return nil }
                    guard let data = try? WESceneInspection.catalog(directory: folder.deletingLastPathComponent(), maxPreviewDimension: 480, sceneName: folder.lastPathComponent),
                          var entry = try? JSONDecoder().decode(SceneCatalogPayload.self, from: data).entries.first,
                          entry.error == nil,
                          (try? MaterialDiscovery.stamp(candidate.url)) == current,
                          ((try? MaterialDiscovery.stamp(folder.appendingPathComponent("project.json"))) ?? "") == meta else { return nil }
                    entry.propertyMetadataStamp = meta
                    return entry
                }.value
                if let result { next[path] = (candidate.stamp, result) }
                else { errors.append(candidate.url.deletingLastPathComponent().lastPathComponent + "：素材未完整或暂不可识别，下次检查时重试") }
            }
            for (path, value) in old where snapshot.2.contains(where: { path.hasPrefix($0.path + "/") }) { next[path] = value }
            guard !Task.isCancelled else { return }
            // A folder added mid-scan triggers a fresh pass; don't publish stale roots.
            if currentRoots != roots { rescanRequested = true; continue }
            cached = next
            scenes = next.values.map(\.1).sorted { ($0.title ?? $0.name).localizedStandardCompare($1.title ?? $1.name) == .orderedAscending }
            issues = errors
            await model.refreshDiscoveredLibrary()
            lastScan = Date()
        } while rescanRequested && !Task.isCancelled
    }
}
