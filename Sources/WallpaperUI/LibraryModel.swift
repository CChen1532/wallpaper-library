import Foundation
import Combine

@MainActor final class LibraryModel: ObservableObject {
    @Published var items: [Wallpaper] = []
    @Published var state = PlaybackState()
    @Published var busy = false
    @Published var loading = false
    @Published var error: String?
    @Published var stateIssue: String?
    @Published var libraryIssue: String?
    @Published var selected: String?
    @Published var diagnostics: BackendDiagnostics?
    @Published var loadingDiagnostics = false
    let backend: any WallpaperBackend
    let scenePlayer: ScenePlayer
    let sceneRuntimeURL: URL
    let scenePreferences: ScenePreferencesStore
    let sceneUserProperties: SceneUserPropertiesStore
    private let backdropConfiguration: @MainActor () throws -> SceneBackdropConfiguration?
    private var shuttingDown = false
    private var sceneRequestRevision = 0
    private var stateRevision = 0
    var capabilities: BackendCapabilities { backend.capabilities }
    var isWorking: Bool { busy || loading || scenePlayer.isTransitioning || shuttingDown }
    var selectedWallpaper: Wallpaper? { items.first { $0.id == selected } }
    var rotationStatusText: String { stateIssue == nil ? (state.rotating ? "已开启" : "已关闭") : "状态未知" }
    var rotationIntervalText: String {
        guard stateIssue == nil else { return "未知" }
        return state.interval.map { $0 % 60 == 0 ? "\($0 / 60) 分钟" : "\($0) 秒" } ?? "未知"
    }
    func selectNextVideo(in visibleIDs: [String], forward: Bool) {
        guard !visibleIDs.isEmpty else { selected = nil; return }
        guard let selected, let index = visibleIDs.firstIndex(of: selected) else {
            self.selected = forward ? visibleIDs.first : visibleIDs.last; return
        }
        self.selected = visibleIDs[min(max(index + (forward ? 1 : -1), 0), visibleIDs.count - 1)]
    }

    init(backend: any WallpaperBackend = PhontoBackend(), scenePlayer: ScenePlayer? = nil,
         sceneRuntimeURL: URL? = nil, scenePreferences: ScenePreferencesStore? = nil,
         sceneUserProperties: SceneUserPropertiesStore? = nil,
         backdropConfiguration: @escaping @MainActor () throws -> SceneBackdropConfiguration? = {
             guard UserDefaults.standard.object(forKey: SceneBackdropConfiguration.preferenceKey) as? Bool ?? true else { return nil }
             return try SceneBackdropConfiguration.bundled()
         }) {
        self.backend = backend
        self.backdropConfiguration = backdropConfiguration
        self.scenePreferences = scenePreferences ?? ScenePreferencesStore()
        self.sceneUserProperties = sceneUserProperties ?? SceneUserPropertiesStore()
        self.scenePlayer = scenePlayer ?? ScenePlayer()
        self.sceneRuntimeURL = sceneRuntimeURL ?? (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appendingPathComponent("SceneRuntime", isDirectory: true)
    }

    var sceneRuntimeAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: sceneRuntimeURL
            .appendingPathComponent("Contents/Resources/Renderers/SceneWallpaper").path)
    }

    func playScene(root: URL, name: String, title: String, expectedBytes: Int64) async {
        guard !isWorking else { return }
        do {
            guard let displayID = scenePlayer.preferredDisplayID() else {
                throw BackendError.message("当前没有可用显示器")
            }
            // Validate all local inputs before changing the current video engine.
            var configuration = try SceneLaunchConfiguration.prepare(
                runtimeURL: sceneRuntimeURL, root: root, name: name, title: title,
                expectedBytes: expectedBytes, displayID: displayID,
                preferences: scenePreferences.preferences(for: root.appendingPathComponent(name).appendingPathComponent("scene.pkg")))
            configuration.setUserProperties(try sceneUserProperties.launch(for: configuration.package))
            configuration.backdrop = try backdropConfiguration()
            let sourcePackage = configuration.package
            configuration.backdrop?.sourcePackage = sourcePackage
            await playPreparedScene(configuration)
        } catch { self.error = error.localizedDescription }
    }

    func isActiveScene(_ package: URL) -> Bool {
        guard scenePlayer.isActive, let active = scenePlayer.package else { return false }
        return ScenePreferencesStore.identity(for: active) == ScenePreferencesStore.identity(for: package)
    }

    func applyScenePreferences(for package: URL) async {
        // A delayed action from B must never reconfigure the currently playing A.
        guard !isWorking, isActiveScene(package) else { return }
        do {
            let bytes = try package.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let folder = package.deletingLastPathComponent()
            await playScene(root: folder.deletingLastPathComponent(), name: folder.lastPathComponent,
                            title: scenePlayer.title, expectedBytes: Int64(bytes))
        } catch { self.error = error.localizedDescription }
    }

    func playPreparedScene(_ configuration: SceneLaunchConfiguration) async {
        guard beginOperation() else { return }
        sceneRequestRevision += 1
        let request = sceneRequestRevision
        defer { busy = false }
        do {
            await scenePlayer.stop()
            try scenePlayer.requireRestoredBackdrop()
            try await backend.perform(.off)
            guard !shuttingDown, request == sceneRequestRevision else { return }
            try Task.checkCancellation()
            try scenePlayer.start(configuration)
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
        await readState()
    }

    func stopScene() async {
        sceneRequestRevision += 1
        await scenePlayer.stop()
    }

    func shutdownScene() async {
        shuttingDown = true
        await stopScene()
    }

    func refreshLibrary() async {
        guard !isWorking else { return }
        loading = true
        defer { loading = false }
        await readLibrary()
        await readState()
    }
    private func readLibrary() async {
        do {
            items = try await backend.library()
            libraryIssue = nil
            if !items.contains(where: { $0.id == selected }) { selected = nil }
        } catch is CancellationError { return }
        catch {
            libraryIssue = error.localizedDescription
            // Do not keep actionable cards for a folder that can no longer be read.
            items = []; selected = nil
        }
    }
    func refreshState() async {
        guard !isWorking else { return }
        await readState()
    }
    private func readState() async {
        stateRevision += 1
        let revision = stateRevision
        do {
            let value = try await backend.state()
            guard revision == stateRevision else { return }
            if scenePlayer.isActive && (value.running || value.rotating) {
                await scenePlayer.stop()
                guard revision == stateRevision else { return }
                error = "检测到视频播放或轮播从外部开启，已停止场景以避免重叠。"
            }
            state = value; stateIssue = nil
        } catch is CancellationError { return }
        catch {
            guard revision == stateRevision else { return }
            stateIssue = error.localizedDescription
        }
    }
    private func beginOperation() -> Bool {
        guard !isWorking else { return false }
        busy = true
        stateRevision += 1 // Invalidate an already-running poll before the mutation.
        return true
    }
    func perform(_ action: Action) async {
        // Stop remains available while the scene is preparing its first frame.
        switch action {
        case .stop, .off:
            guard !busy, !shuttingDown else { return }
            busy = true; stateRevision += 1
        default:
            guard beginOperation() else { return }
        }
        defer { busy = false }
        do {
            switch action {
            case .play, .next, .previous, .random, .rotation, .stop, .off:
                await scenePlayer.stop()
            case .stopRotation: break
            }
            guard !shuttingDown else { return }
            switch action {
            case .play, .next, .previous, .random, .rotation: try scenePlayer.requireRestoredBackdrop()
            default: break
            }
            try await backend.perform(action)
        }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
        await readState()
    }
    func importFiles(_ urls: [URL]) async {
        guard capabilities.canImport, beginOperation() else { return }
        defer { busy = false }
        let problems = await backend.importFiles(urls)
        if !problems.isEmpty { error = problems.joined(separator: "\n") }
        await readLibrary()
        await readState()
    }
    func trashSelected() async {
        guard capabilities.canTrash, let item = selectedWallpaper, beginOperation() else { return }
        defer { busy = false }
        do {
            try await backend.trash(item.url)
            selected = nil
            await readLibrary()
        } catch { self.error = error.localizedDescription }
        await readState()
    }
    func refreshDiagnostics() async {
        guard !loadingDiagnostics, !isWorking else { return }
        loadingDiagnostics = true
        defer { loadingDiagnostics = false }
        do { diagnostics = try await backend.diagnostics() }
        catch { self.error = error.localizedDescription }
    }
}
