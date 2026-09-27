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
    @Published var videoBackdropIssue: String?
    @Published var backdropCompatibilityIssue: String?
    let backend: any WallpaperBackend
    let scenePlayer: ScenePlayer
    let sceneRuntimeURL: URL
    let scenePreferences: ScenePreferencesStore
    let sceneUserProperties: SceneUserPropertiesStore
    let scenePreparation: ScenePreparationCache
    let videoBackdropPreferences: VideoBackdropPreferencesStore
    let videoBackdrop: VideoBackdropController
    private let backdropConfiguration: @MainActor () throws -> SceneBackdropConfiguration?
    private var shuttingDown = false
    private var sceneRequestRevision = 0
    private var stateRevision = 0
    private var lastVideoBackdropAttempt: String?
    private var backdropsReady = false
    var capabilities: BackendCapabilities { backend.capabilities }
    var isWorking: Bool { busy || loading || scenePlayer.isTransitioning || videoBackdrop.transitioning || shuttingDown }
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
         scenePreparation: ScenePreparationCache? = nil,
         videoBackdropPreferences: VideoBackdropPreferencesStore? = nil,
         videoBackdrop: VideoBackdropController? = nil,
         backdropConfiguration: @escaping @MainActor () throws -> SceneBackdropConfiguration? = {
             guard SceneBackdropConfiguration.isEnabled() else { return nil }
             return try SceneBackdropConfiguration.bundled()
         }) {
        self.backend = backend
        self.backdropConfiguration = backdropConfiguration
        self.scenePreferences = scenePreferences ?? ScenePreferencesStore()
        self.sceneUserProperties = sceneUserProperties ?? SceneUserPropertiesStore()
        self.scenePreparation = scenePreparation ?? ScenePreparationCache()
        self.videoBackdropPreferences = videoBackdropPreferences ?? VideoBackdropPreferencesStore()
        self.videoBackdrop = videoBackdrop ?? VideoBackdropController()
        self.scenePlayer = scenePlayer ?? ScenePlayer()
        self.sceneRuntimeURL = sceneRuntimeURL ?? (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appendingPathComponent("SceneRuntime", isDirectory: true)
    }

    var sceneRuntimeAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: sceneRuntimeURL
            .appendingPathComponent("Contents/Resources/Renderers/SceneWallpaper").path)
    }

    func playScene(root: URL, name: String, title: String, expectedBytes: Int64,
                   updatingEffects: Bool = false) async {
        guard beginOperation() else { return }
        sceneRequestRevision += 1
        let request = sceneRequestRevision
        defer { busy = false }
        do {
            let package = root.appendingPathComponent(name).appendingPathComponent("scene.pkg")
            let preferences = scenePreferences.preferences(for: package)
            if updatingEffects {
                let launch = try await sceneUserProperties.launchInBackground(for: package)
                guard !shuttingDown, request == sceneRequestRevision else { return }
                if scenePlayer.canApplyEffectsLive(for: package, preferences: preferences,
                                                   values: launch.effectiveValues) {
                    try await scenePlayer.applyEffectsLive(for: package, preferences: preferences,
                                                          values: launch.effectiveValues)
                    return
                }
            }
            guard let displayID = scenePlayer.preferredDisplayID(preferences: preferences) else {
                throw BackendError.message("当前没有可用显示器")
            }
            // Preflight filesystem work stays off the UI actor. The cache was
            // warmed when this Scene was selected, but still revalidates here.
            var configuration = try await scenePreparation.prepare(
                runtimeURL: sceneRuntimeURL, root: root, name: name, title: title,
                expectedBytes: expectedBytes, displayID: displayID,
                preferences: preferences)
            guard !shuttingDown, request == sceneRequestRevision else { return }
            configuration.setUserProperties(try await sceneUserProperties.launchInBackground(for: configuration.package))
            configuration.backdrop = try backdropConfiguration()
            let sourcePackage = configuration.package
            configuration.backdrop?.sourcePackage = sourcePackage
            guard !shuttingDown, request == sceneRequestRevision else { return }
            try await commitPreparedScene(configuration, request: request)
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
        await readState()
    }

    func preloadScene(root: URL, name: String, title: String, expectedBytes: Int64) async {
        let package = root.appendingPathComponent(name).appendingPathComponent("scene.pkg")
        let preferences = scenePreferences.preferences(for: package)
        guard let displayID = scenePlayer.preferredDisplayID(preferences: preferences) else { return }
        _ = try? await scenePreparation.prepare(runtimeURL: sceneRuntimeURL, root: root, name: name,
                                                title: title, expectedBytes: expectedBytes,
                                                displayID: displayID, preferences: preferences)
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
                            title: scenePlayer.title, expectedBytes: Int64(bytes), updatingEffects: true)
        } catch { self.error = error.localizedDescription }
    }

    func playPreparedScene(_ configuration: SceneLaunchConfiguration) async {
        guard beginOperation() else { return }
        sceneRequestRevision += 1
        let request = sceneRequestRevision
        defer { busy = false }
        do { try await commitPreparedScene(configuration, request: request) }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
        await readState()
    }

    private func commitPreparedScene(_ prepared: SceneLaunchConfiguration, request: Int) async throws {
        await scenePlayer.stop()
        try scenePlayer.requireRestoredBackdrop()
        try await backend.perform(.off)
        try await videoBackdrop.stop()
        try videoBackdrop.requireRestoredBackdrop()
        lastVideoBackdropAttempt = nil
        guard !shuttingDown, request == sceneRequestRevision else { return }
        try Task.checkCancellation()
        var configuration = prepared
        if configuration.backdrop != nil, scenePlayer.connectedDisplays.count > 1 {
            // The system's all-Spaces switch also affects other monitors.
            // Keep playback available without changing that shared setting.
            configuration.backdrop = nil
            backdropCompatibilityIssue = "多屏模式下暂不启用 Space 过渡底图，场景仍可选择或跟随显示器播放。"
        } else {
            backdropCompatibilityIssue = nil
        }
        if let backdrop = configuration.backdrop {
            do {
                try await SpaceBackdropCompatibility.check(backdrop, displayID: configuration.displayID)
                backdropCompatibilityIssue = nil
            } catch let mismatch as SpaceBackdropCompatibilityFailure {
                UserDefaults.standard.set(false, forKey: SceneBackdropConfiguration.preferenceKey)
                backdropCompatibilityIssue = "已自动关闭场景过渡底图：" + mismatch.localizedDescription
                configuration.backdrop = nil
            }
        }
        guard !shuttingDown, request == sceneRequestRevision else { return }
        try scenePlayer.start(configuration)
    }

    func stopScene() async {
        sceneRequestRevision += 1
        await scenePlayer.stop()
    }

    func shutdownScene() async {
        shuttingDown = true
        await stopScene()
        if videoBackdrop.hasSession {
            do { try await backend.perform(.off) }
            catch { self.error = "退出时停止视频失败：" + error.localizedDescription }
        }
        do { try await videoBackdrop.stop() }
        catch { self.error = "退出时恢复视频底图失败：" + error.localizedDescription }
    }

    func recoverBackdrops() async {
        await scenePlayer.recoverBackdrop()
        do { try await videoBackdrop.recover() }
        catch { videoBackdropIssue = "恢复原壁纸失败：" + error.localizedDescription }
        backdropsReady = !scenePlayer.restorationPending && !videoBackdrop.restorationPending
    }

    func recoverVideoBackdrop() async {
        guard !isWorking else { return }
        do {
            try await videoBackdrop.recover()
            videoBackdropIssue = nil; lastVideoBackdropAttempt = nil
            backdropsReady = !scenePlayer.restorationPending && !videoBackdrop.restorationPending
        }
        catch { videoBackdropIssue = "恢复原壁纸失败：" + error.localizedDescription }
    }

    func applyVideoBackdropPreferences(for video: URL) async {
        guard state.currentPath == video.path, beginOperation() else { return }
        defer { busy = false }
        await readState(forceVideoBackdrop: true)
    }

    func refreshLibrary() async {
        guard !isWorking else { return }
        loading = true
        defer { loading = false }
        await readLibrary()
        await readState()
    }
    /// Inventory refresh has no playback/state/backdrop side effects.
    func refreshDiscoveredLibrary() async {
        guard !isWorking else { return }
        loading = true
        defer { loading = false }
        await readLibrary()
    }
    private func readLibrary() async {
        do {
            let discovered = try await backend.library()
            if items != discovered { items = discovered }
            if libraryIssue != nil { libraryIssue = nil }
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
    private func readState(forceVideoBackdrop: Bool = false) async {
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
            // Polling must still reconcile engines and backdrops, but an unchanged
            // status should not invalidate every gallery card and inspector control.
            if state != value { state = value }
            if stateIssue != nil { stateIssue = nil }
            await syncVideoBackdrop(for: value, force: forceVideoBackdrop, revision: revision)
        } catch is CancellationError { return }
        catch {
            guard revision == stateRevision else { return }
            let issue = error.localizedDescription
            if stateIssue != issue { stateIssue = issue }
        }
    }

    private func syncVideoBackdrop(for value: PlaybackState, force: Bool, revision: Int) async {
        guard backdropsReady, revision == stateRevision, !shuttingDown else { return }
        guard !scenePlayer.isActive else { return }
        guard let path = value.currentPath, !path.isEmpty else {
            lastVideoBackdropAttempt = nil
            if videoBackdrop.hasSession {
                do {
                    try await videoBackdrop.stop()
                    guard revision == stateRevision, !shuttingDown else { return }
                    videoBackdropIssue = nil
                } catch {
                    guard revision == stateRevision, !shuttingDown else { return }
                    videoBackdropIssue = "恢复原壁纸失败：" + error.localizedDescription
                }
            }
            return
        }
        let video = URL(fileURLWithPath: path)
        guard let directory = capabilities.libraryDirectory,
              (video.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL || items.contains(where: { $0.id == path })) else { return }
        var preferences = videoBackdropPreferences.preferences(for: video)
        if let item = items.first(where: { $0.id == path }) {
            preferences.frameSecond = min(preferences.frameSecond, max(0, Int(item.duration.rounded(.down)) - 1))
        }
        if videoBackdrop.matches(video: video, preferences: preferences) { videoBackdropIssue = nil; return }
        let attempt = path + "|\(preferences.enabled)|\(preferences.frameSecond)"
        guard force || lastVideoBackdropAttempt != attempt else { return }
        lastVideoBackdropAttempt = attempt
        do {
            if preferences.enabled {
                guard let displayID = scenePlayer.preferredDisplayID() else {
                    throw BackendError.message("当前没有可用显示器")
                }
                try await videoBackdrop.activate(video: video, preferences: preferences, displayID: displayID)
            } else {
                try await videoBackdrop.stop()
            }
            guard revision == stateRevision, !shuttingDown else { return }
            videoBackdropIssue = nil
        } catch is CancellationError { return }
        catch let mismatch as SpaceBackdropCompatibilityFailure {
            guard revision == stateRevision, !shuttingDown else { return }
            preferences.enabled = false
            videoBackdropPreferences.save(preferences, for: video)
            backdropCompatibilityIssue = "已自动关闭此视频的过渡底图：" + mismatch.localizedDescription
            videoBackdropIssue = nil
        } catch {
            guard revision == stateRevision, !shuttingDown else { return }
            videoBackdropIssue = "视频 Space 过渡底图未匹配：" + error.localizedDescription
            if force { self.error = videoBackdropIssue }
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
            switch action {
            case .stop, .off:
                try await videoBackdrop.stop()
                lastVideoBackdropAttempt = nil
            default: break
            }
        }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
        await readState(forceVideoBackdrop: true)
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
