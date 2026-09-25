import AppKit
import Combine
import Foundation
#if canImport(MirageSceneBridge)
import MirageSceneBridge
#endif

enum ScenePlaybackPhase { case stopped, starting, playing, stopping, failed }

struct SceneLaunchConfiguration: Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]?
    let package: URL
    let title: String
    let displayID: UInt32
    var preferences = ScenePreferences()

    static func prepare(runtimeURL: URL, root: URL, name: String, title: String,
                        expectedBytes: Int64, displayID: UInt32, preferences: ScenePreferences = .init()) throws -> Self {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else {
            throw BackendError.message("场景目录名称无效")
        }
        let folder = root.appendingPathComponent(name, isDirectory: true)
        for url in [root, folder] {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw BackendError.message("场景必须位于所选目录内，不能使用链接目录")
            }
        }
        let package = folder.appendingPathComponent("scene.pkg")
        let size = try package.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, Int64(size) == expectedBytes else {
            throw BackendError.message("场景包已变化，请刷新场景目录")
        }
        let position: Double
        switch preferences.cropMode {
        case "auto": position = name == "1000000001" ? 1 : 0.5
        case "left": position = 0
        case "center": position = 0.5
        case "right": position = 1
        default: throw BackendError.message("画面位置设置无效")
        }
        let runtime = try MirageSceneRuntime(app: runtimeURL)
        let arguments = try runtime.playbackArguments(scenePackage: package, displayID: displayID,
                                                      fps: preferences.fps, horizontalCropPosition: position,
                                                      mouseEnabled: preferences.mouseEnabled,
                                                      mouseButtonsEnabled: preferences.mouseButtonsEnabled,
                                                      inputHz: preferences.inputHz,
                                                      soundEnabled: preferences.soundEnabled,
                                                      audioResponseEnabled: preferences.audioResponseEnabled)
        return Self(executable: runtime.executable, arguments: arguments,
                    environment: runtime.environment(), package: package,
                    title: title, displayID: displayID, preferences: preferences)
    }
}

/// A single worker owns each renderer from launch through cleanup. Cancelling
/// never races a second writer against the renderer's stdin.
@MainActor final class ScenePlayer: ObservableObject {
    @Published private(set) var phase: ScenePlaybackPhase = .stopped
    @Published private(set) var title = ""
    @Published private(set) var package: URL?
    @Published private(set) var displayID: UInt32?
    @Published private(set) var error: String?
    @Published private(set) var activePreferences: ScenePreferences?
    private var worker: Task<Void, Never>?
    private var generation = UUID()
    private let focusProvider: @MainActor @Sendable () -> UInt32?

    init(focusProvider: @escaping @MainActor @Sendable () -> UInt32? = { FocusDisplaySelector.currentDisplay() }) {
        self.focusProvider = focusProvider
    }

    var isActive: Bool { worker != nil }
    func preferredDisplayID() -> UInt32? { focusProvider() }
    var isTransitioning: Bool { phase == .starting || phase == .stopping }
    var statusText: String {
        switch phase {
        case .stopped: return "场景未播放"
        case .starting: return "正在准备场景…"
        case .playing: return "场景正在桌面播放"
        case .stopping: return "正在停止场景…"
        case .failed: return "场景播放失败"
        }
    }

    func start(_ configuration: SceneLaunchConfiguration) throws {
        guard worker == nil else { throw BackendError.message("上一个场景尚未停止，请稍候") }
        let token = UUID()
        generation = token
        phase = .starting
        activePreferences = configuration.preferences
        title = configuration.title
        package = configuration.package
        displayID = configuration.displayID
        error = nil
        let focus = focusProvider
        worker = Task.detached(priority: .userInitiated) { [weak self] in
            let child = MirageSceneChild(executable: configuration.executable,
                                         arguments: configuration.arguments,
                                         environment: configuration.environment)
            var failure: String?
            do {
                try Task.checkCancellation()
                try child.start()
                try await Self.waitUntil(timeout: 60) { try child.eventReceived("scene-ready") }
                try await Self.waitUntil(timeout: 15) { try child.eventReceived("first-frame-presented") }
                try Task.checkCancellation()
                try child.send("activate")
                try await Self.waitUntil(timeout: 5) { try child.eventReceived("activated") }
                await self?.activated(token: token)
                var handoff = FocusDisplayHandoff(currentDisplayID: configuration.displayID)
                while !Task.isCancelled {
                    // A successful activation is historical; still check liveness.
                    _ = try child.eventReceived("activated")
                    let target = configuration.preferences.followsDisplay ? await focus() : nil
                    try Task.checkCancellation()
                    if configuration.preferences.followsDisplay,
                       let move = handoff.observe(target, at: ProcessInfo.processInfo.systemUptime) {
                        try child.move(to: move)
                        try await Self.waitUntil(timeout: 2) { try child.moveAcknowledged(to: move) }
                        await self?.moved(to: move, token: token)
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
            } catch is CancellationError { }
            catch { failure = error.localizedDescription }
            child.stop()
            await self?.finished(token: token, failure: failure)
        }
    }

    func stop() async {
        guard let task = worker else {
            if phase == .failed { phase = .stopped; error = nil }
            return
        }
        let token = generation
        phase = .stopping
        task.cancel()
        await task.value
        // A newer session must never be cleared by an older stop continuation.
        guard generation == token else { return }
        worker = nil
        phase = .stopped
        package = nil
        activePreferences = nil
        displayID = nil
        error = nil
    }

    private func activated(token: UUID) {
        guard token == generation, phase == .starting else { return }
        phase = .playing
    }
    private func moved(to displayID: UInt32, token: UUID) {
        guard token == generation, phase == .playing else { return }
        self.displayID = displayID
    }
    private func finished(token: UUID, failure: String?) {
        guard token == generation else { return }
        // stop() owns the final transition while awaiting cleanup.
        guard phase != .stopping else { return }
        worker = nil
        error = failure
        phase = failure == nil ? .stopped : .failed
        package = nil
        activePreferences = nil
        displayID = nil
    }
    nonisolated private static func waitUntil(timeout: TimeInterval, predicate: () throws -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            try Task.checkCancellation()
            if try predicate() { return }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw MirageSceneBridgeError.failed("场景渲染器响应超时")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    deinit { worker?.cancel() }
}
