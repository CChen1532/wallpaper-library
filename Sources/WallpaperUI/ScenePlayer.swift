import AppKit
import Combine
import Foundation
import ImageIO
#if canImport(GravitySceneCore)
import GravitySceneCore
#endif
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
    var supportsLiveProperties = false

    static func prepare(runtimeURL: URL, root: URL, name: String, title: String,
                        expectedBytes: Int64, displayID: UInt32, preferences: ScenePreferences = .init()) throws -> Self {
        let package = try validatedPackage(root: root, name: name, expectedBytes: expectedBytes)
        if try MoonScene.load(package) != nil {
            let executable = runtimeURL.deletingLastPathComponent().appendingPathComponent("MoonSceneRenderer")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw BackendError.message("当前应用缺少月球场景渲染器，请重新构建应用")
            }
            var arguments = ["--assets", package.deletingLastPathComponent().appendingPathComponent("assets").path,
                             "--display-id", String(displayID), "--control-stdin", "--deferred-show"]
            if !preferences.mouseEnabled { arguments.append("--no-mouse") }
            if !preferences.mouseButtonsEnabled { arguments.append("--no-mouse-buttons") }
            return Self(executable: executable, arguments: arguments, environment: nil, package: package,
                        title: title, displayID: displayID, preferences: preferences, supportsLiveProperties: true)
        }
        if let native = try GravityScene.load(package) {
            let executable = runtimeURL.deletingLastPathComponent().appendingPathComponent("GravitySceneRenderer")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw BackendError.message("当前应用缺少引力场景渲染器，请重新构建应用")
            }
            var automatic = preferences
            automatic.mouseEnabled = false
            automatic.mouseButtonsEnabled = false
            automatic.fps = native.preset.fps
            return Self(executable: executable,
                        arguments: ["--preset", native.preset.rawValue, "--display-id", String(displayID),
                                    "--control-stdin", "--deferred-show"], environment: nil,
                        package: package, title: title, displayID: displayID, preferences: automatic)
        }
        let position = preferences.position(for: package)
        let runtime = try MirageSceneRuntime(app: runtimeURL)
        let arguments = try runtime.playbackArguments(scenePackage: package, displayID: displayID,
                                                      fps: preferences.fps, horizontalCropPosition: position.0,
                                                      mouseEnabled: preferences.mouseEnabled,
                                                      mouseButtonsEnabled: preferences.mouseButtonsEnabled,
                                                      inputHz: preferences.inputHz,
                                                      soundEnabled: preferences.soundEnabled,
                                                      audioResponseEnabled: preferences.audioResponseEnabled,
                                                      renderScale: preferences.renderScale, metalFX: preferences.metalFX,
                                                      msaa: preferences.msaa, fillMode: preferences.fillMode,
                                                      verticalPosition: position.1)
        return Self(executable: runtime.executable, arguments: arguments,
                    environment: runtime.environment(), package: package,
                    title: title, displayID: displayID, preferences: preferences, supportsLiveProperties: true)
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
        if !["GravitySceneRenderer", "MoonSceneRenderer"].contains(executable.lastPathComponent), let file = launch.file {
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
    @Published private(set) var notice: String?
    @Published private(set) var activePreferences: ScenePreferences?
    @Published private(set) var activeUserPropertyValues: [String: ScenePropertyValue] = [:]
    @Published private(set) var restorationPending = false
    @Published private(set) var recoveringBackdrop = false
    @Published private(set) var automaticBackdropActive = false
    @Published private(set) var automaticBackdropImage: URL?
    @Published private(set) var preparingBackdrop = false
    @Published private(set) var applyingEffects = false
    @Published private(set) var exporting = false
    @Published private(set) var manualPause = false
    @Published private(set) var powerReason: String?
    @Published private(set) var effectivePaused = false
    @Published private(set) var mediaStatus = "媒体信息未开启"
    private var mediaPayload: Data?
    private var mediaTask: Task<Void, Never>?
    private var supportsLiveProperties = false
    private struct ExportRequest: Sendable {
        let action: SceneExportAction
        let completion: CheckedContinuation<Void, Error>
    }
    private var pendingExport: ExportRequest?
    private var lastShortcutAt = Date.distantPast
    private let mediaProvider = SceneMediaProvider()
    private struct PropertyUpdate: Sendable {
        let values: [String: ScenePropertyValue]
        let changes: [String: ScenePropertyValue]
        let preferences: ScenePreferences
        let completion: CheckedContinuation<Void, Error>
    }
    private var pendingProperties: PropertyUpdate?
    private let backdropFactory: @Sendable (SceneBackdropConfiguration) -> any SceneBackdropControlling
    private var worker: Task<Void, Never>?
    private var generation = UUID()
    private let focusProvider: @MainActor @Sendable () -> UInt32?
    private let displayProvider: @MainActor @Sendable () -> [SceneDisplay]

    init(focusProvider: @escaping @MainActor @Sendable () -> UInt32? = { FocusDisplaySelector.currentDisplay() },
         displayProvider: @escaping @MainActor @Sendable () -> [SceneDisplay] = { SceneDisplay.connected() },
         backdropFactory: @escaping @Sendable (SceneBackdropConfiguration) -> any SceneBackdropControlling = { SceneBackdropLease(configuration: $0) }) {
        self.focusProvider = focusProvider
        self.displayProvider = displayProvider
        self.backdropFactory = backdropFactory
    }

    var isActive: Bool { worker != nil }
    var supportsControls: Bool { phase == .playing && supportsLiveProperties }
    func togglePause() { if supportsControls { manualPause.toggle() } }
    var connectedDisplays: [SceneDisplay] { displayProvider() }
    func preferredDisplayID(preferences: ScenePreferences = .init()) -> UInt32? {
        SceneDisplay.resolve(preferences, displays: displayProvider(), focus: focusProvider())
    }
    var isTransitioning: Bool { phase == .starting || phase == .stopping || recoveringBackdrop || applyingEffects || exporting }
    var statusText: String {
        switch phase {
        case .stopped: return "场景未播放"
        case .starting: return preparingBackdrop ? "正在准备场景与 Space 过渡底图…" : "正在准备场景…"
        case .playing: return applyingEffects ? "正在应用场景效果…" : powerReason ?? "场景正在桌面播放"
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
        supportsLiveProperties = configuration.supportsLiveProperties
        title = configuration.title
        package = configuration.package
        displayID = configuration.displayID
        manualPause = false
        powerReason = nil
        effectivePaused = false
        mediaPayload = nil
        preparingBackdrop = configuration.backdrop != nil
        error = nil
        notice = nil
        let focus = focusProvider
        let displays = displayProvider
        let backdropFactory = backdropFactory
        worker = Task.detached(priority: .userInitiated) { [weak self] in
            let child = MirageSceneChild(executable: configuration.executable,
                                         arguments: configuration.arguments,
                                         environment: configuration.environment)
            var backdrop = configuration.backdrop.map { backdropFactory($0) }
            var failure: String?
            do {
                try Task.checkCancellation()
                if await displays().count > 1, backdrop != nil {
                    backdrop = nil
                    await self?.backdropSuspended(token: token)
                }
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
                if configuration.supportsLiveProperties {
                    try Self.configure(child, preferences: configuration.preferences, package: configuration.package)
                }
                try child.send("activate")
                try await Self.waitUntil(timeout: 5) { try child.eventReceived("activated") }
                await self?.activated(token: token)
                var lastPower: ScenePowerDecision?
                var lastMuted: Bool?
                var lastMedia: Data?
                var environment = ScenePowerEnvironment()
                var nextEnvironmentCheck = ContinuousClock.now
                var handoff = FocusDisplayHandoff(currentDisplayID: configuration.displayID)
                while !Task.isCancelled {
                    // A successful activation is historical; still check liveness.
                    _ = try child.eventReceived("activated")
                    let available = await displays()
                    if available.count > 1, let activeBackdrop = backdrop {
                        // Restore the owned single-display lease before moving
                        // onto a topology where the global switch is unsafe.
                        try activeBackdrop.finish()
                        backdrop = nil
                        await self?.backdropSuspended(token: token)
                    }
                    try backdrop?.checkHealth()
                    if let update = await self?.takePropertyUpdate(token: token) {
                        do {
                            try Task.checkCancellation()
                            try child.setProperties(update.changes.mapValues(\.controlValue))
                            try Self.configure(child, preferences: update.preferences, package: configuration.package)
                            lastPower = nil
                            lastMuted = nil
                            _ = try child.eventReceived("activated")
                            if let self { await self.completePropertyUpdate(update, token: token) }
                            else { update.completion.resume(throwing: CancellationError()) }
                        } catch {
                            update.completion.resume(throwing: error)
                            throw error
                        }
                    }
                    if configuration.supportsLiveProperties {
                        if ContinuousClock.now >= nextEnvironmentCheck {
                            environment = await self?.powerEnvironment(displayID: handoff.currentDisplayID) ?? .init()
                            nextEnvironmentCheck = ContinuousClock.now.advanced(by: .seconds(2))
                        }
                        if let state = await self?.runtimeState(token: token, environment: environment) {
                            if state.0 != lastPower {
                                try child.control(["cmd": "power", "state": state.0.state, "fps": state.0.fps])
                                lastPower = state.0
                            }
                            if state.1 != lastMuted {
                                try child.control(["cmd": "muted", "value": state.1])
                                lastMuted = state.1
                            }
                            if let media = state.2, media != lastMedia {
                                let payload = try JSONSerialization.jsonObject(with: media)
                                try child.control(["cmd": "mediaStatus", "data": payload])
                                lastMedia = media
                            }
                        }
                        let shortcuts = child.takeShortcuts()
                        if !shortcuts.isEmpty { await self?.handleShortcuts(shortcuts, token: token) }
                    }
                    if let request = await self?.takeExport(token: token) {
                        do {
                            try Task.checkCancellation()
                            try Self.performExport(request.action, child: child)
                            await self?.exportFinished(token: token)
                            request.completion.resume()
                        } catch {
                            await self?.exportFinished(token: token)
                            request.completion.resume(throwing: error)
                        }
                    }
                    let needsFocus = configuration.preferences.followsDisplay ||
                        !available.contains(where: { $0.id == handoff.currentDisplayID })
                    let focusedDisplay = needsFocus ? await focus() : nil
                    let target = SceneDisplay.resolve(configuration.preferences,
                        displays: available, focus: focusedDisplay, current: handoff.currentDisplayID)
                    try Task.checkCancellation()
                    if let move = handoff.observe(target, at: ProcessInfo.processInfo.systemUptime) {
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
                        if let backdrop {
                            await self?.backdropActivated(token: token, image: backdrop.previewURL)
                        }
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
        notice = nil
    }

    func canApplyEffectsLive(for package: URL, preferences: ScenePreferences,
                             values: [String: ScenePropertyValue]) -> Bool {
        phase == .playing && worker != nil && !applyingEffects && supportsLiveProperties &&
            self.package == package && activePreferences.map({ preferences.canUpdateLive(from: $0) }) == true &&
            Set(activeUserPropertyValues.keys) == Set(values.keys)
    }

    func applyEffectsLive(for package: URL, preferences: ScenePreferences,
                          values: [String: ScenePropertyValue]) async throws {
        try Task.checkCancellation()
        guard canApplyEffectsLive(for: package, preferences: preferences, values: values) else {
            throw BackendError.message("当前场景状态已变化，请重新应用设置")
        }
        let changes = values.filter { activeUserPropertyValues[$0.key] != $0.value }
        guard !changes.isEmpty || activePreferences != preferences else { return }
        applyingEffects = true
        try await withCheckedThrowingContinuation { continuation in
            pendingProperties = PropertyUpdate(values: values, changes: changes, preferences: preferences, completion: continuation)
        }
    }

    private func takePropertyUpdate(token: UUID) -> PropertyUpdate? {
        guard token == generation, phase == .playing else { return nil }
        defer { pendingProperties = nil }
        return pendingProperties
    }

    private func completePropertyUpdate(_ update: PropertyUpdate, token: UUID) {
        guard token == generation, phase == .playing else {
            update.completion.resume(throwing: CancellationError())
            return
        }
        let mediaChanged = activePreferences?.mediaInfoEnabled != update.preferences.mediaInfoEnabled
        activePreferences = update.preferences
        if mediaChanged { mediaPayload = nil; restartMediaTask(token: token) }
        activeUserPropertyValues = update.values
        applyingEffects = false
        update.completion.resume()
    }

    nonisolated private static func configure(_ child: MirageSceneChild, preferences: ScenePreferences, package: URL) throws {
        let position = preferences.position(for: package)
        try child.control(["cmd": "volume", "value": preferences.volume])
        try child.control(["cmd": "speed", "value": preferences.speed])
        try child.control(["cmd": "fillmode", "value": preferences.fillMode])
        try child.control(["cmd": "position", "x": position.0, "y": position.1])
    }

    private func powerEnvironment(displayID: UInt32) -> ScenePowerEnvironment {
        guard let preferences = activePreferences, preferences.energySaving || preferences.pauseWhenCovered else { return .init() }
        return ScenePowerEnvironment.current(displayID: displayID, checkCoverage: preferences.pauseWhenCovered)
    }
    private func runtimeState(token: UUID, environment: ScenePowerEnvironment) -> (ScenePowerDecision, Bool, Data?)? {
        guard token == generation, phase == .playing, let preferences = activePreferences else { return nil }
        let power = ScenePowerDecision.resolve(preferences, manualPause: manualPause, environment: environment)
        if powerReason != power.reason { powerReason = power.reason }
        if effectivePaused != (power.state == "pause") { effectivePaused = power.state == "pause" }
        let media = preferences.mediaInfoEnabled ? mediaPayload : SceneMediaProvider.empty
        return (power, !preferences.soundEnabled || power.state == "pause", media)
    }

    private func restartMediaTask(token: UUID) {
        mediaTask?.cancel(); mediaTask = nil
        guard activePreferences?.mediaInfoEnabled == true else {
            mediaPayload = nil; mediaStatus = "媒体信息未开启"; return
        }
        mediaTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, token == self.generation, self.phase == .playing else { return }
                if self.activePreferences?.mediaInfoEnabled == true {
                    let result = await self.mediaProvider.read()
                    guard !Task.isCancelled, token == self.generation else { return }
                    self.mediaPayload = result.data
                    if self.mediaStatus != result.status { self.mediaStatus = result.status }
                } else {
                    self.mediaPayload = nil
                    if self.mediaStatus != "媒体信息未开启" { self.mediaStatus = "媒体信息未开启" }
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    private func handleShortcuts(_ events: [(String, String)], token: UUID) {
        guard token == generation, activePreferences?.shortcutsEnabled == true, !effectivePaused,
              Date().timeIntervalSince(lastShortcutAt) > 1, let package else { return }
        let catalog = ScenePropertyCatalog.load(for: package)
        for (name, value) in events {
            guard catalog.properties.contains(where: { $0.id == name && $0.kind == .shortcut }),
                  activeUserPropertyValues[name] == .string(value), let target = SceneShortcut.target(value) else { continue }
            lastShortcutAt = Date()
            NSWorkspace.shared.open(target)
            break
        }
    }

    func export(_ action: SceneExportAction, for package: URL) async throws {
        guard self.package == package, supportsControls, !isTransitioning else {
            throw BackendError.message("请先播放此场景，再执行此操作")
        }
        exporting = true
        try await withCheckedThrowingContinuation { continuation in
            pendingExport = ExportRequest(action: action, completion: continuation)
        }
    }
    private func exportFinished(token: UUID) { if token == generation { exporting = false } }
    private func takeExport(token: UUID) -> ExportRequest? {
        guard token == generation, phase == .playing else { return nil }
        defer { pendingExport = nil }
        return pendingExport
    }
    nonisolated private static func performExport(_ action: SceneExportAction, child: MirageSceneChild) throws {
        switch action {
        case .screenshot(let destination):
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let frame = directory.appendingPathComponent("frame.heic")
            try child.snapshot(to: frame)
            guard let source = CGImageSourceCreateWithURL(frame as CFURL, nil),
                  let bitmap = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw BackendError.message("静帧导出失败") }
            let data = NSMutableData()
            guard let target = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw BackendError.message("静帧导出失败") }
            CGImageDestinationAddImage(target, bitmap, nil)
            guard CGImageDestinationFinalize(target) else { throw BackendError.message("静帧导出失败") }
            try Task.checkCancellation()
            try (data as Data).write(to: destination, options: .atomic)
        case .storage(let destination):
            try child.exportStorage().write(to: destination, options: .atomic)
        case .resetStorage(let backup):
            try child.exportStorage().write(to: backup, options: .atomic)
            try child.control(["cmd": "resetScriptStorage"])
        }
    }

    private func backdropSuspended(token: UUID) {
        guard token == generation else { return }
        automaticBackdropActive = false
        automaticBackdropImage = nil
        preparingBackdrop = false
        notice = "多屏模式下暂不启用 Space 过渡底图，场景仍可选择或跟随显示器播放。"
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
        restartMediaTask(token: token)
    }
    private func moved(to displayID: UInt32, token: UUID) {
        guard token == generation, phase == .playing else { return }
        self.displayID = displayID
    }
    private func finished(token: UUID, failure: String?, pending: Bool) {
        guard token == generation else { return }
        pendingProperties?.completion.resume(throwing: CancellationError())
        pendingProperties = nil
        applyingEffects = false
        supportsLiveProperties = false
        pendingExport?.completion.resume(throwing: CancellationError())
        pendingExport = nil
        exporting = false
        mediaTask?.cancel(); mediaTask = nil; mediaPayload = nil
        manualPause = false; powerReason = nil; effectivePaused = false
        mediaStatus = "媒体信息未开启"
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
