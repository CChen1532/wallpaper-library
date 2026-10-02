import AppKit
import Combine
import Foundation

/// Each display owns a complete scene/video/rotation lifecycle. The library and
/// preferences are shared; selecting a screen never transfers an active player.
@MainActor final class DisplayPlayback: ObservableObject {
    @Published private(set) var displays: [SceneDisplay] = []
    @Published var selectedUUID: String = ""
    @Published private(set) var issue: String?
    @Published private(set) var lifecycleBusy = true
    let library: LibraryModel
    private(set) var sessions: [String: LibraryModel] = [:]
    private var observers: [AnyCancellable] = []
    private let displayProvider: @MainActor () -> [SceneDisplay]
    private let makeSession: (SceneDisplay) -> LibraryModel
    private let recover: (() async -> Bool)?
    private var initialized = false
    private var ready = false
    private var reconciling = false
    private var refreshRequested = false
    private var shuttingDown = false

    init(library: LibraryModel, displayProvider: @escaping @MainActor () -> [SceneDisplay] = { SceneDisplay.connected() },
         makeSession: ((SceneDisplay) -> LibraryModel)? = nil, recover: (() async -> Bool)? = nil) {
        self.library = library
        library.inventoryOnly = true
        self.recover = recover
        self.displayProvider = displayProvider
        self.makeSession = makeSession ?? { display in
            LibraryModel(backend: PhontoBackend(displayUUID: display.uuid),
                scenePlayer: ScenePlayer(pinnedDisplayUUID: display.uuid), targetDisplayUUID: display.uuid,
                scenePreferences: library.scenePreferences, sceneUserProperties: library.sceneUserProperties,
                scenePreparation: library.scenePreparation, videoBackdropPreferences: library.videoBackdropPreferences,
                collection: library.collection)
        }
        displays = displayProvider()
        for display in displays { addSession(display) }
        selectedUUID = displays.first?.uuid ?? ""
        library.beforeMaterialRemoval = { [weak self] target in
            guard let self else { return }
            for session in self.sessions.values { try await self.stopSessionPlaybackForRemoval(session, target: target) }
        }
        observers.append(library.$items.sink { [weak self] items in
            for session in self?.sessions.values ?? [:].values where session.items != items { session.items = items }
        })
        observers.append(library.$libraryIssue.sink { [weak self] issue in
            for session in self?.sessions.values ?? [:].values { session.libraryIssue = issue }
        })
    }

    var selected: LibraryModel { sessions[selectedUUID] ?? library }
    var busy: Bool { lifecycleBusy || library.busy || sessions.values.contains { $0.busy || $0.scenePlayer.isTransitioning } }
    var needsRecovery: Bool { !ready || sessions.values.contains { $0.scenePlayer.restorationPending || $0.videoBackdrop.restorationPending } }
    var hasPlayback: Bool { sessions.values.contains { $0.scenePlayer.isActive || $0.state.running || $0.isRotating } }

    private func addSession(_ display: SceneDisplay) {
        guard sessions[display.uuid] == nil else { return }
        let session = makeSession(display)
        sessions[display.uuid] = session
        session.items = library.items
        session.libraryIssue = library.libraryIssue
        session.finishDisplayStartup(recovered: ready)
        session.playbackBlocker = { [weak self] in
            self?.needsRecovery == true ? "原壁纸尚未恢复，请在设置中点击“恢复原壁纸”后再播放" : nil
        }
        session.otherDisplayBusy = { [weak self, weak session] in
            guard let self, let session else { return true }
            return self.lifecycleBusy || self.library.busy || self.sessions.values.contains { $0 !== session && $0.busy }
        }
        session.beforeMaterialRemoval = { [weak self, weak session] target in
            guard let self else { return }
            for other in self.sessions.values where other !== session {
                try await self.stopSessionPlaybackForRemoval(other, target: target)
            }
        }
        observers.append(session.objectWillChange.sink { [weak self] in self?.objectWillChange.send() })
        observers.append(session.scenePlayer.objectWillChange.sink { [weak self] in self?.objectWillChange.send() })
    }

    private func stopSessionPlaybackForRemoval(_ session: LibraryModel, target: URL) async throws {
        // The caller already blocks new operations through library.busy or its
        // own session.busy. Finish another display's existing command first.
        while session.busy {
            guard !shuttingDown else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard !shuttingDown else { throw CancellationError() }
        try await session.stopLocalPlaybackForRemoval(target)
    }

    func start() async {
        if let recover { ready = await recover() }
        else {
            await library.recoverBackdrops()
            ready = !library.scenePlayer.restorationPending && !library.videoBackdrop.restorationPending
        }
        if !ready { issue = "原壁纸尚未恢复，请在设置中点击“恢复原壁纸”后再播放" }
        for session in sessions.values { session.finishDisplayStartup(recovered: ready) }
        initialized = true
        lifecycleBusy = false
        await refreshDisplays()
    }

    func recoverBackdrops() async {
        guard !busy, !hasPlayback else { return }
        lifecycleBusy = true
        defer { lifecycleBusy = false }
        await library.recoverBackdrops()
        ready = !library.scenePlayer.restorationPending && !library.videoBackdrop.restorationPending
        for session in sessions.values {
            await session.recoverBackdrops()
            ready = ready && !session.scenePlayer.restorationPending && !session.videoBackdrop.restorationPending
        }
        for session in sessions.values { session.finishDisplayStartup(recovered: ready) }
        issue = ready ? nil : "原壁纸尚未恢复，请在设置中点击“恢复原壁纸”后再播放"
    }

    func refreshDisplays() async {
        guard !shuttingDown else { return }
        guard initialized, !lifecycleBusy else { refreshRequested = true; return }
        guard !reconciling else { refreshRequested = true; return }
        reconciling = true
        defer { reconciling = false }
        repeat {
            refreshRequested = false
            let updated = displayProvider()
            guard updated != displays else { continue }
            lifecycleBusy = true
            for old in displays where !updated.contains(where: { $0.uuid == old.uuid && $0.id == old.id }) {
                await sessions[old.uuid]?.disconnectDisplay()
                issue = "显示器已断开，该屏幕播放已停止。重新连接后可再次选择壁纸。"
            }
            guard !shuttingDown else { return }
            displays = updated
            for display in updated { addSession(display) }
            if !updated.contains(where: { $0.uuid == selectedUUID }) { selectedUUID = updated.first?.uuid ?? "" }
            lifecycleBusy = false
        } while refreshRequested && !shuttingDown
    }

    func poll() async {
        await refreshDisplays()
        guard !lifecycleBusy, !shuttingDown else { return }
        for display in displays { await sessions[display.uuid]?.refreshState() }
    }

    func stopAll() async {
        guard !lifecycleBusy else { return }
        lifecycleBusy = true
        defer { lifecycleBusy = false }
        for session in sessions.values { await session.disconnectDisplay() }
        do { try await library.backend.perform(.off) }
        catch { issue = error.localizedDescription }
    }

    func suspend() async {
        while lifecycleBusy && !shuttingDown { try? await Task.sleep(for: .milliseconds(50)) }
        guard !shuttingDown else { return }
        await stopAll()
    }

    func shutdown() async {
        shuttingDown = true
        lifecycleBusy = true
        for session in sessions.values { await session.shutdownScene() }
        await library.shutdownScene()
        do { try await library.backend.perform(.off) }
        catch { issue = error.localizedDescription }
    }

    func label(for display: SceneDisplay) -> String {
        let index = (displays.firstIndex(of: display) ?? 0) + 1
        return "\(index) · \(display.name)"
    }

    func playingTitle(for display: SceneDisplay) -> String? {
        guard let model = sessions[display.uuid] else { return nil }
        if model.scenePlayer.isActive { return model.scenePlayer.title }
        return model.state.currentPath.map { path in
            model.items.first { $0.id == path }?.title ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
    }
}
