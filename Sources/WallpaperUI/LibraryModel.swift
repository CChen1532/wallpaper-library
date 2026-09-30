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
    let targetDisplayUUID: String?
    var playbackBlocker: () -> String? = { nil }
    var otherDisplayBusy: () -> Bool = { false }
    var inventoryOnly = false
    var beforeMaterialRemoval: ((URL) async throws -> Void)?
    var displayConnected: Bool {
        targetDisplayUUID.map { uuid in scenePlayer.connectedDisplays.contains { $0.uuid == uuid } } ?? true
    }
    func playbackPreferences(for package: URL) -> ScenePreferences {
        var value = scenePreferences.preferences(for: package)
        if let targetDisplayUUID {
            value.followsDisplay = false
            value.displayUUID = targetDisplayUUID
            value.displayName = scenePlayer.connectedDisplays.first { $0.uuid == targetDisplayUUID }?.name
        }
        return value
    }
    let backend: any WallpaperBackend
    let scenePlayer: ScenePlayer
    let sceneRuntimeURL: URL
    let scenePreferences: ScenePreferencesStore
    let sceneUserProperties: SceneUserPropertiesStore
    let scenePreparation: ScenePreparationCache
    let videoBackdropPreferences: VideoBackdropPreferencesStore
    let videoBackdrop: VideoBackdropController
    let collection: LibraryCollectionStore
    private var rotationObserver: AnyCancellable?
    lazy var selectionRotation: SelectionRotation = {
        let rotation = SelectionRotation(items: { [weak self] in self?.collection.rotationCandidates ?? [] },
            ready: { [weak self] in self.map { !$0.isWorking && !$0.shuttingDown } ?? false },
            play: { [weak self] item in await self?.playRotationItem(item) ?? false },
            failure: { [weak self] in self?.error })
        rotationObserver = rotation.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        return rotation
    }()
    private let trashItem: (URL) throws -> Void
    private let backdropConfiguration: @MainActor () throws -> SceneBackdropConfiguration?
    private var shuttingDown = false
    private var sceneRequestRevision = 0
    private var stateRevision = 0
    private var lastVideoBackdropAttempt: String?
    private var backdropsReady = false
    var capabilities: BackendCapabilities { backend.capabilities }
    var isWorking: Bool { busy || loading || scenePlayer.isTransitioning || videoBackdrop.transitioning || shuttingDown || otherDisplayBusy() || !displayConnected }
    var selectedWallpaper: Wallpaper? { items.first { $0.id == selected } }
    var isRotating: Bool { selectionRotation.active || state.rotating }
    var rotationStatusText: String { selectionRotation.active ? "所选壁纸轮播中" : stateIssue == nil ? (state.rotating ? "已开启" : "已关闭") : "状态未知" }
    var rotationIntervalText: String {
        guard selectionRotation.active || stateIssue == nil else { return "未知" }
        let interval = selectionRotation.active ? collection.interval : state.interval
        return interval.map { $0 % 60 == 0 ? "\($0 / 60) 分钟" : "\($0) 秒" } ?? "未知"
    }
    func selectNextVideo(in visibleIDs: [String], forward: Bool) {
        guard !visibleIDs.isEmpty else { selected = nil; return }
        guard let selected, let index = visibleIDs.firstIndex(of: selected) else {
            self.selected = forward ? visibleIDs.first : visibleIDs.last; return
        }
        self.selected = visibleIDs[min(max(index + (forward ? 1 : -1), 0), visibleIDs.count - 1)]
    }

    init(backend: any WallpaperBackend = PhontoBackend(), scenePlayer: ScenePlayer? = nil,
         targetDisplayUUID: String? = nil,
         sceneRuntimeURL: URL? = nil, scenePreferences: ScenePreferencesStore? = nil,
         sceneUserProperties: SceneUserPropertiesStore? = nil,
         scenePreparation: ScenePreparationCache? = nil,
         videoBackdropPreferences: VideoBackdropPreferencesStore? = nil,
         videoBackdrop: VideoBackdropController? = nil,
         collection: LibraryCollectionStore? = nil,
         trashItem: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
         backdropConfiguration: @escaping @MainActor () throws -> SceneBackdropConfiguration? = {
             guard SceneBackdropConfiguration.isEnabled() else { return nil }
             return try SceneBackdropConfiguration.bundled()
         }) {
        self.backend = backend
        self.targetDisplayUUID = targetDisplayUUID
        self.trashItem = trashItem
        self.backdropConfiguration = backdropConfiguration
        self.scenePreferences = scenePreferences ?? ScenePreferencesStore()
        self.sceneUserProperties = sceneUserProperties ?? SceneUserPropertiesStore()
        self.scenePreparation = scenePreparation ?? ScenePreparationCache()
        self.videoBackdropPreferences = videoBackdropPreferences ?? VideoBackdropPreferencesStore()
        self.videoBackdrop = videoBackdrop ?? VideoBackdropController()
        self.collection = collection ?? LibraryCollectionStore()
        self.scenePlayer = scenePlayer ?? ScenePlayer()
        self.sceneRuntimeURL = sceneRuntimeURL ?? (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appendingPathComponent("SceneRuntime", isDirectory: true)
    }

    var sceneRuntimeAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: sceneRuntimeURL
            .appendingPathComponent("Contents/Resources/Renderers/SceneWallpaper").path)
    }

    func playScene(root: URL, name: String, title: String, expectedBytes: Int64,
                   updatingEffects: Bool = false, fromSelectionRotation: Bool = false) async {
        if let issue = playbackBlocker() { error = issue; return }
        guard beginOperation() else { return }
        if !fromSelectionRotation && !updatingEffects { selectionRotation.stop() }
        sceneRequestRevision += 1
        let request = sceneRequestRevision
        defer { busy = false }
        do {
            let package = root.appendingPathComponent(name).appendingPathComponent("scene.pkg")
            let preferences = playbackPreferences(for: package)
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
            if configuration.supportsLiveProperties {
                let storagePackage = configuration.package
                let storageDisplay = targetDisplayUUID
                let storage = try await Task.detached(priority: .utility) {
                    try SceneScriptStorage.prepare(package: storagePackage, displayUUID: storageDisplay)
                }.value
                configuration.arguments.insert(contentsOf: ["--script-storage-dir", storage.path], at: configuration.arguments.count - 2)
            }
            configuration.backdrop = scenePlayer.connectedDisplays.count > 1 ? nil : try backdropConfiguration()
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
        let preferences = playbackPreferences(for: package)
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
        selectionRotation.stop()
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
                backdropCompatibilityIssue = "场景过渡底图未就绪：" + mismatch.localizedDescription
                // Read-only preflight has made no system writes; playback remains available.
                configuration.backdrop = nil
            }
        }
        guard !shuttingDown, request == sceneRequestRevision else { return }
        guard displayConnected else { throw BackendError.message("目标显示器已断开，请重新选择显示器") }
        try scenePlayer.start(configuration)
    }

    func stopScene() async {
        selectionRotation.stop()
        sceneRequestRevision += 1
        await scenePlayer.stop()
    }

    func disconnectDisplay() async {
        sceneRequestRevision += 1
        selectionRotation.stop()
        await selectionRotation.finishPendingSwitch()
        while busy { try? await Task.sleep(for: .milliseconds(50)) }
        await perform(.off)
    }

    func suspendForSystem() async {
        if targetDisplayUUID != nil { await disconnectDisplay(); return }
        let wasSelectedRotation = selectionRotation.active || selectionRotation.switching
        selectionRotation.stop()
        sceneRequestRevision += 1
        await selectionRotation.finishPendingSwitch()
        if wasSelectedRotation { await perform(.off) }
        else { await stopScene() }
    }

    func shutdownScene() async {
        let wasSelectedRotation = selectionRotation.active || selectionRotation.switching
        shuttingDown = true
        sceneRequestRevision += 1
        selectionRotation.stop()
        await selectionRotation.finishPendingSwitch()
        while busy { try? await Task.sleep(for: .milliseconds(50)) }
        await stopScene()
        if videoBackdrop.hasSession || wasSelectedRotation || targetDisplayUUID != nil {
            do { try await backend.perform(.off) }
            catch { self.error = "退出时停止视频失败：" + error.localizedDescription }
        }
        do { try await videoBackdrop.stop() }
        catch { self.error = "退出时恢复视频底图失败：" + error.localizedDescription }
    }

    func finishDisplayStartup(recovered: Bool) { backdropsReady = recovered }

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
            if selectionRotation.active, !selectionRotation.switching, !scenePlayer.isTransitioning,
               let id = selectionRotation.currentID {
                let activeScene = scenePlayer.package.map { LibraryCollectionStore.identity($0) == id } == true && scenePlayer.isActive
                let activeVideo = value.currentPath.map { LibraryCollectionStore.identity(URL(fileURLWithPath: $0)) == id } == true
                if value.rotating || (!activeScene && !activeVideo) {
                    selectionRotation.halt("播放已从外部停止或切换，所选壁纸轮播已暂停。")
                }
            }
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
        if targetDisplayUUID != nil && scenePlayer.connectedDisplays.count > 1 {
            do { try await videoBackdrop.stop(); videoBackdropIssue = nil }
            catch { videoBackdropIssue = error.localizedDescription }
            lastVideoBackdropAttempt = nil
            return
        }
        guard !scenePlayer.isActive, !otherDisplayBusy() else { return }
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
            backdropCompatibilityIssue = "此视频的过渡底图未就绪：" + mismatch.localizedDescription
            videoBackdropIssue = backdropCompatibilityIssue
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
    func perform(_ action: Action, fromSelectionRotation: Bool = false) async {
        switch action {
        case .play, .next, .previous, .random, .rotation:
            if let issue = playbackBlocker() { error = issue; return }
        default: break
        }
        if !fromSelectionRotation, selectionRotation.active {
            switch action {
            case .next: selectionRotation.advance(.next); return
            case .previous: selectionRotation.advance(.previous); return
            case .random: selectionRotation.advance(.random); return
            default: break
            }
        }
        // Stop remains available while the scene is preparing its first frame.
        switch action {
        case .stop, .off:
            guard !busy, !shuttingDown else { return }
            busy = true; stateRevision += 1
        default:
            guard beginOperation() else { return }
        }
        if !fromSelectionRotation { selectionRotation.stop() }
        defer { busy = false }
        do {
            if fromSelectionRotation { try await backend.perform(.stopRotation) }
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
            var routedAction = action
            if targetDisplayUUID != nil {
                switch action {
                case .next, .previous, .random:
                    let candidates = items.filter { $0.playable && !collection.hiddenIDs.contains(LibraryCollectionStore.identity($0.url)) }
                    guard !candidates.isEmpty else { throw BackendError.message("没有可播放的视频") }
                    let current = candidates.firstIndex { $0.id == state.currentPath }
                    let index: Int
                    switch action {
                    case .random: index = candidates.indices.filter { $0 != current }.randomElement() ?? 0
                    case .previous: index = current.map { ($0 + candidates.count - 1) % candidates.count } ?? candidates.count - 1
                    default: index = current.map { ($0 + 1) % candidates.count } ?? 0
                    }
                    routedAction = .play(candidates[index].url.path)
                default: break
                }
                switch routedAction {
                case .play, .rotation:
                    guard displayConnected else { throw BackendError.message("目标显示器已断开，请重新选择显示器") }
                default: break
                }
            }
            try await backend.perform(routedAction)
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
    /// Stop only playback affected by a removal, and require successful backdrop restoration.
    private func stopForMaterialRemoval(_ target: URL) async throws {
        try await beforeMaterialRemoval?(target)
        try await stopLocalPlaybackForRemoval(target)
    }
    func stopLocalPlaybackForRemoval(_ target: URL) async throws {
        guard !inventoryOnly else { return }
        stateRevision += 1
        if collection.rotationItems.contains(where: { MaterialRemoval.contains(target, $0.url) }) {
            selectionRotation.stop()
        }
        if let package = scenePlayer.package, MaterialRemoval.contains(target, package) {
            await scenePlayer.stop()
            try scenePlayer.requireRestoredBackdrop()
        }
        let actual = try await backend.state()
        let affectsRotation = actual.rotating && (capabilities.libraryDirectory.map {
            MaterialRemoval.contains($0, target) || MaterialRemoval.contains(target, $0)
        } ?? true)
        if affectsRotation || actual.currentPath.map({ MaterialRemoval.contains(target, URL(fileURLWithPath: $0)) }) == true {
            try await backend.perform(.off)
            try await videoBackdrop.stop()
            state = try await backend.state()
            lastVideoBackdropAttempt = nil
        }
    }
    func prepareMaterialRemoval(_ target: URL) async -> Bool {
        guard beginOperation() else { return false }
        defer { busy = false }
        do { try await stopForMaterialRemoval(target); await readState(); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func trashWallpaper(payload: URL, confirmedTarget: URL, confirmedStamp: String, roots: [URL]) async -> Bool {
        guard beginOperation() else { return false }
        defer { busy = false }
        do {
            guard try MaterialRemoval.target(for: payload, roots: roots) == confirmedTarget,
                  try MaterialDiscovery.stamp(payload) == confirmedStamp else { throw BackendError.message("文件已改变，请重新选择后再删除。") }
            try await stopForMaterialRemoval(confirmedTarget)
            guard try MaterialRemoval.target(for: payload, roots: roots) == confirmedTarget,
                  try MaterialDiscovery.stamp(payload) == confirmedStamp else { throw BackendError.message("文件已改变，请重新选择后再删除。") }
            try trashItem(confirmedTarget)
            collection.forgetRemovedTargets([confirmedTarget])
            await readLibrary(); await readState()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func startSelectedRotation(interval: Int, mode: String) {
        guard !isWorking, !selectionRotation.switching, collection.rotationCandidates.count >= 2,
              (60...86400).contains(interval), ["rand", "next"].contains(mode) else { return }
        collection.configureRotation(interval: interval, mode: mode)
        error = nil
        selectionRotation.start(interval: Double(interval), mode: mode)
    }

    func trashWallpapers(_ requests: [MaterialRemoval.Request], roots: [URL]) async -> MaterialRemoval.BatchResult {
        var result = MaterialRemoval.BatchResult()
        guard beginOperation() else { result.failures = ["当前操作尚未完成，请稍后重试。"]; return result }
        defer { busy = false }
        var processed = Set<String>()
        for request in requests {
            guard processed.insert(request.id).inserted else { continue }
            do {
                func validate() throws {
                    guard try MaterialRemoval.target(for: request.payload, roots: roots) == request.target,
                          try MaterialDiscovery.stamp(request.payload) == request.stamp else {
                        throw BackendError.message("文件已改变，请重新选择后再删除。")
                    }
                }
                try validate()
                try await stopForMaterialRemoval(request.target)
                try validate()
                guard !shuttingDown else { throw CancellationError() }
                try trashItem(request.target)
                result.removed.append(request.target)
            } catch {
                result.failures.append(request.title + ": " + error.localizedDescription)
            }
        }
        if !result.removed.isEmpty { collection.forgetRemovedTargets(result.removed) }
        await readLibrary(); await readState()
        return result
    }

    private func playRotationItem(_ item: RotationWallpaper) async -> Bool {
        guard !isWorking, !shuttingDown, !collection.hiddenIDs.contains(item.id) else { return false }
        error = nil
        switch item.kind {
        case .scene:
            let folder = item.url.deletingLastPathComponent()
            await playScene(root: folder.deletingLastPathComponent(), name: folder.lastPathComponent,
                            title: item.title, expectedBytes: item.expectedBytes, fromSelectionRotation: true)
            return error == nil && isActiveScene(item.url)
        case .video:
            await perform(.play(item.url.path), fromSelectionRotation: true)
            return error == nil && state.currentPath.map { LibraryCollectionStore.identity(URL(fileURLWithPath: $0)) == item.id } == true
        }
    }
    func refreshDiagnostics() async {
        guard !loadingDiagnostics, !isWorking else { return }
        loadingDiagnostics = true
        defer { loadingDiagnostics = false }
        do { diagnostics = try await backend.diagnostics() }
        catch { self.error = error.localizedDescription }
    }
}
