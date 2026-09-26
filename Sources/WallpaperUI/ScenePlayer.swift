import AppKit
import Combine
import Foundation
#if canImport(MirageSceneBridge)
import MirageSceneBridge
#endif

enum ScenePlaybackPhase { case stopped, starting, playing, stopping, failed }

struct SceneLaunchConfiguration: Sendable {
    let executable: URL
    var arguments: [String]
    let environment: [String: String]?
    let package: URL
    let title: String
    let displayID: UInt32
    var preferences = ScenePreferences()
    var userPropertyValues: [String: ScenePropertyValue] = [:]
    var backdrop: SceneBackdropConfiguration?

    static func prepare(runtimeURL: URL, root: URL, name: String, title: String,
                        expectedBytes: Int64, displayID: UInt32, preferences: ScenePreferences = .init()) throws -> Self {
        let package = try validatedPackage(root: root, name: name, expectedBytes: expectedBytes)
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

    static func validatedPackage(root: URL, name: String, expectedBytes: Int64) throws -> URL {
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
        let values = try package.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, Int64(size) == expectedBytes else {
            throw BackendError.message("场景包已变化，请刷新场景目录")
        }
        return package
    }

    mutating func setUserProperties(_ launch: ScenePropertyLaunch) {
        userPropertyValues = launch.effectiveValues
        if let file = launch.file {
            // Mirage reads this before scene parsing and before the first captured frame.
            arguments.insert(contentsOf: ["--user-properties", file.path], at: arguments.count - 2)
        }
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
    @Published private(set) var activeUserPropertyValues: [String: ScenePropertyValue] = [:]
    @Published private(set) var restorationPending = false
    @Published private(set) var recoveringBackdrop = false
    @Published private(set) var automaticBackdropActive = false
    @Published private(set) var automaticBackdropImage: URL?
    @Published private(set) var preparingBackdrop = false
    private let backdropFactory: @Sendable (SceneBackdropConfiguration) -> any SceneBackdropControlling
    private var worker: Task<Void, Never>?
    private var generation = UUID()
    private let focusProvider: @MainActor @Sendable () -> UInt32?

    init(focusProvider: @escaping @MainActor @Sendable () -> UInt32? = { FocusDisplaySelector.currentDisplay() },
         backdropFactory: @escaping @Sendable (SceneBackdropConfiguration) -> any SceneBackdropControlling = { SceneBackdropLease(configuration: $0) }) {
        self.focusProvider = focusProvider
        self.backdropFactory = backdropFactory
    }

    var isActive: Bool { worker != nil }
    func preferredDisplayID() -> UInt32? { focusProvider() }
    var isTransitioning: Bool { phase == .starting || phase == .stopping || recoveringBackdrop }
    var statusText: String {
        switch phase {
        case .stopped: return "场景未播放"
        case .starting: return preparingBackdrop ? "正在准备场景与 Space 过渡底图…" : "正在准备场景…"
        case .playing: return "场景正在桌面播放"
        case .stopping: return "正在停止场景…"
        case .failed: return "场景播放失败"
        }
    }

    func requireRestoredBackdrop() throws {
        guard !restorationPending, !recoveringBackdrop else {
            throw BackendError.message("原壁纸尚未恢复，请在设置中点击“恢复原壁纸”后再播放")
        }
    }

    func recoverBackdrop() async {
        guard worker == nil, !recoveringBackdrop else { return }
        recoveringBackdrop = true
        defer { recoveringBackdrop = false }
        do {
            let configuration = try SceneBackdropConfiguration.bundled()
            try await Task.detached { try SceneBackdropLease.recover(configuration) }.value
            restorationPending = false
            error = nil
            phase = .stopped
        } catch {
            restorationPending = true
            self.error = "恢复原壁纸失败：" + error.localizedDescription
            phase = .failed
        }
    }

    func start(_ configuration: SceneLaunchConfiguration) throws {
        guard worker == nil else { throw BackendError.message("上一个场景尚未停止，请稍候") }
        try requireRestoredBackdrop()
        let token = UUID()
        generation = token
        phase = .starting
        activePreferences = configuration.preferences
        activeUserPropertyValues = configuration.userPropertyValues
        title = configuration.title
        package = configuration.package
        displayID = configuration.displayID
        preparingBackdrop = configuration.backdrop != nil
        error = nil
        let focus = focusProvider
        let backdropFactory = backdropFactory
        worker = Task.detached(priority: .userInitiated) { [weak self] in
            let child = MirageSceneChild(executable: configuration.executable,
                                         arguments: configuration.arguments,
                                         environment: configuration.environment)
            let backdrop = configuration.backdrop.map { backdropFactory($0) }
            var failure: String?
            do {
                try Task.checkCancellation()
                try child.start()
                try await Self.waitUntil(timeout: 60) { try child.eventReceived("scene-ready") }
                try await Self.waitUntil(timeout: 15) { try child.eventReceived("first-frame-presented") }
                try Task.checkCancellation()
                if let backdrop {
                    let opening = SceneBackdropFrameSampler.openingEnabled(
                        package: configuration.package, values: configuration.userPropertyValues)
                    try backdrop.activate(displayID: configuration.displayID) { output in
                        try SceneBackdropFrameSampler.capture(to: output, openingEnabled: opening) {
                            try child.snapshot(to: $0)
                        }
                    }
                    if let image = backdrop.registrationURL {
                        try await SpaceWallpaperSettingsController.activate(displayID: configuration.displayID, imageURL: image)
                    }
                    await self?.backdropActivated(token: token, image: backdrop.previewURL)
                }
                try Task.checkCancellation()
                try child.send("activate")
                try await Self.waitUntil(timeout: 5) { try child.eventReceived("activated") }
                await self?.activated(token: token)
                var handoff = FocusDisplayHandoff(currentDisplayID: configuration.displayID)
                while !Task.isCancelled {
                    // A successful activation is historical; still check liveness.
                    _ = try child.eventReceived("activated")
                    try backdrop?.checkHealth()
                    let target = configuration.preferences.followsDisplay ? await focus() : nil
                    try Task.checkCancellation()
                    if configuration.preferences.followsDisplay,
                       let move = handoff.observe(target, at: ProcessInfo.processInfo.systemUptime) {
                        try backdrop?.finish()
                        try Task.checkCancellation()
                        try child.move(to: move)
                        try await Self.waitUntil(timeout: 2) { try child.moveAcknowledged(to: move) }
                        try backdrop?.activate(displayID: move) { output in
                            try SceneBackdropFrameSampler.capture(to: output, openingEnabled: false) {
                                try child.snapshot(to: $0)
                            }
                        }
                        if let image = backdrop?.registrationURL {
                            try await SpaceWallpaperSettingsController.activate(displayID: move, imageURL: image)
                        }
                        await self?.backdropActivated(token: token, image: backdrop?.previewURL)
                        await self?.moved(to: move, token: token)
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
            } catch is CancellationError { }
            catch let mismatch as SpaceBackdropCompatibilityFailure {
                await MainActor.run {
                    UserDefaults.standard.set(false, forKey: SceneBackdropConfiguration.preferenceKey)
                }
                failure = "已自动关闭场景过渡底图：" + mismatch.localizedDescription
            }
            catch { failure = error.localizedDescription }
            do { try backdrop?.finish() }
            catch { failure = [failure, "恢复底图：" + error.localizedDescription].compactMap { $0 }.joined(separator: "\n") }
            child.stop()
            await self?.finished(token: token, failure: failure, pending: backdrop?.recoveryPending ?? false)
        }
    }

    func stop() async {
        guard let task = worker else {
            if phase == .failed && !restorationPending { phase = .stopped; error = nil }
            return
        }
        let token = generation
        phase = .stopping
        task.cancel()
        await task.value
        // A newer session must never be cleared by an older stop continuation.
        guard generation == token else { return }
        worker = nil
        phase = error == nil ? .stopped : .failed
        package = nil
        activePreferences = nil
        activeUserPropertyValues = [:]
        displayID = nil
        preparingBackdrop = false
    }

    private func backdropActivated(token: UUID, image: URL?) {
        guard token == generation else { return }
        automaticBackdropActive = true
        automaticBackdropImage = image
    }
    private func activated(token: UUID) {
        guard token == generation, phase == .starting else { return }
        preparingBackdrop = false
        phase = .playing
    }
    private func moved(to displayID: UInt32, token: UUID) {
        guard token == generation, phase == .playing else { return }
        self.displayID = displayID
    }
    private func finished(token: UUID, failure: String?, pending: Bool) {
        guard token == generation else { return }
        error = failure
        restorationPending = pending
        automaticBackdropActive = false
        automaticBackdropImage = nil
        preparingBackdrop = false
        // stop() owns the final transition while awaiting cleanup.
        guard phase != .stopping else { return }
        worker = nil
        error = failure
        phase = failure == nil ? .stopped : .failed
        package = nil
        activePreferences = nil
        activeUserPropertyValues = [:]
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
