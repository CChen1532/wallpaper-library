import AppKit
import Combine
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct VideoBackdropPreferences: Codable, Equatable, Sendable {
    var enabled = true
    var frameSecond = 0
}

/// The canonical MP4 path is the preference identity. The decoded frame cache
/// also includes file size and modification time, so replacing an MP4 cannot
/// accidentally reuse its predecessor's pixels.
@MainActor final class VideoBackdropPreferencesStore: ObservableObject {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func key(for video: URL) -> String {
        "videoBackdrop.v1.item." + video.standardizedFileURL.resolvingSymlinksInPath().path
    }
    func preferences(for video: URL) -> VideoBackdropPreferences {
        guard let data = defaults.data(forKey: Self.key(for: video)),
              let value = try? JSONDecoder().decode(VideoBackdropPreferences.self, from: data) else { return .init() }
        return .init(enabled: value.enabled, frameSecond: max(0, value.frameSecond))
    }
    func save(_ value: VideoBackdropPreferences, for video: URL) {
        let normalized = VideoBackdropPreferences(enabled: value.enabled, frameSecond: max(0, value.frameSecond))
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        objectWillChange.send()
        defaults.set(data, forKey: Self.key(for: video))
    }
}

enum VideoBackdropFrame {
    static func capture(video: URL, second: Int, width: Int, height: Int,
                        state: URL, ffmpeg: URL, runner: any CommandExecuting = CommandRunner()) async throws -> URL {
        guard second >= 0, width > 0, height > 0, width <= 8192, height <= 8192 else {
            throw BackendError.message("视频截帧参数无效")
        }
        let values = try video.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard video.pathExtension.lowercased() == "mp4", values.isRegularFile == true,
              values.isSymbolicLink != true else { throw BackendError.message("视频素材不可读取") }
        let stamp = try MaterialDiscovery.stamp(video)
        let identity = "\(video.standardizedFileURL.resolvingSymlinksInPath().path)|\(stamp)|\(second)|\(width)x\(height)"
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = state.appendingPathComponent("VideoCaptures/" + key, isDirectory: true)
        let target = directory.appendingPathComponent("wallpaper.png")
        if validImage(target, width: width, height: height) { return target }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent("." + UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let filter = "scale=\(width):\(height):force_original_aspect_ratio=increase,crop=\(width):\(height),setsar=1"
        let result = try await runner.run(ffmpeg.path, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                                                        "-ss", String(second), "-i", video.path, "-frames:v", "1",
                                                        "-vf", filter, "-an", temporary.path], timeout: 30)
        guard result.code == 0, validImage(temporary, width: width, height: height) else {
            throw BackendError.message("无法从当前视频生成匹配的过渡静帧。" + result.message)
        }
        // Atomic replacement keeps a reader from ever seeing a partial PNG.
        try Data(contentsOf: temporary).write(to: target, options: .atomic)
        return target
    }

    private static func validImage(_ url: URL, width: Int, height: Int) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == width,
              properties[kCGImagePropertyPixelHeight] as? Int == height else { return false }
        return true
    }
}

private struct VideoBackdropTarget: Equatable {
    let path: String
    let preferences: VideoBackdropPreferences
    let displayID: UInt32
}

/// Owns the system-picture lease only while this UI is alive. Changes to the
/// actual phonto video are observed by LibraryModel and reconciled here.
@MainActor final class VideoBackdropController: ObservableObject {
    @Published private(set) var activePath: String?
    @Published private(set) var imageURL: URL?
    @Published private(set) var transitioning = false
    @Published private(set) var restorationPending = false
    @Published private(set) var issue: String?
    private var target: VideoBackdropTarget?
    private var lease: SceneBackdropLease?
    private var activationTask: Task<Void, Error>?
    private var transitionWaiters: [CheckedContinuation<Void, Never>] = []
    private let configuration: () throws -> SceneBackdropConfiguration
    private let runner: any CommandExecuting
    private let ffmpeg: URL
    private let activateSystemWallpaper: @MainActor (UInt32, URL) async throws -> Void

    init(configuration: @escaping () throws -> SceneBackdropConfiguration = { try .bundled() },
         runner: any CommandExecuting = CommandRunner(),
         ffmpeg: URL = RuntimeTools.executable("ffmpeg"),
         activateSystemWallpaper: @escaping @MainActor (UInt32, URL) async throws -> Void = { display, image in
             try await SpaceWallpaperSettingsController.activate(displayID: display, imageURL: image)
         }) {
        self.configuration = configuration
        self.runner = runner
        self.ffmpeg = ffmpeg
        self.activateSystemWallpaper = activateSystemWallpaper
    }

    var hasSession: Bool { activationTask != nil || lease != nil }

    func matches(video: URL, preferences: VideoBackdropPreferences) -> Bool {
        if restorationPending { return false }
        if !preferences.enabled { return lease == nil }
        return target?.path == video.path && target?.preferences == preferences && lease != nil
    }

    func requireRestoredBackdrop() throws {
        guard !restorationPending else {
            throw BackendError.message("原壁纸尚未恢复，请先点击“恢复原壁纸”")
        }
    }

    func activate(video: URL, preferences: VideoBackdropPreferences, displayID: UInt32) async throws {
        guard !transitioning else { throw BackendError.message("视频过渡底图正在切换") }
        transitioning = true
        let task = Task { @MainActor in
            defer {
                activationTask = nil
                finishTransition()
            }
            try Task.checkCancellation()
            try await prepare(video: video, preferences: preferences, displayID: displayID)
        }
        activationTask = task
        try await withTaskCancellationHandler(operation: { try await task.value },
                                              onCancel: { task.cancel() })
    }

    private func prepare(video: URL, preferences: VideoBackdropPreferences, displayID: UInt32) async throws {
        try await finishLease()
        try Task.checkCancellation()
        guard preferences.enabled else { issue = nil; return }
        try requireRestoredBackdrop()
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { throw BackendError.message("当前显示器不可用，未设置视频过渡底图") }
        let width = Int((screen.frame.width * screen.backingScaleFactor).rounded())
        let height = Int((screen.frame.height * screen.backingScaleFactor).rounded())
        var settings = try configuration()
        settings.sourcePackage = video
        do {
            try await SpaceBackdropCompatibility.check(settings, displayID: displayID)
            try Task.checkCancellation()
            let frame = try await VideoBackdropFrame.capture(video: video, second: preferences.frameSecond,
                                                              width: width, height: height, state: settings.state,
                                                              ffmpeg: ffmpeg, runner: runner)
            try Task.checkCancellation()
            let session = SceneBackdropLease(configuration: settings)
            lease = session
            let registration = Task.detached(priority: .userInitiated) {
                try session.activatePreparedImage(displayID: displayID, image: frame)
            }
            try await withTaskCancellationHandler(operation: { try await registration.value },
                                                  onCancel: { registration.cancel() })
            try Task.checkCancellation()
            guard let registered = session.registrationURL else {
                throw BackendError.message("系统未登记视频过渡静帧")
            }
            try await activateSystemWallpaper(displayID, registered)
            try Task.checkCancellation()
            target = VideoBackdropTarget(path: video.path, preferences: preferences, displayID: displayID)
            activePath = video.path
            imageURL = frame
            issue = nil
        } catch {
            let original = error.localizedDescription
            let compatibility = error as? SpaceBackdropCompatibilityFailure
            do { try await finishLease() }
            catch { issue = original + "；恢复底图失败：" + error.localizedDescription; throw BackendError.message(issue!) }
            if error is CancellationError { issue = nil; throw CancellationError() }
            issue = original
            if let compatibility { throw compatibility }
            throw BackendError.message(original)
        }
    }

    func stop() async throws {
        // The activation owner restores its lease before waking stop/quit.
        // Waiters also serialize concurrent stop calls and recovery operations.
        while transitioning {
            activationTask?.cancel()
            await withCheckedContinuation { transitionWaiters.append($0) }
        }
        transitioning = true
        defer { finishTransition() }
        try await finishLease()
        try requireRestoredBackdrop()
        issue = nil
    }

    private func finishTransition() {
        transitioning = false
        let waiters = transitionWaiters
        transitionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func finishLease() async throws {
        guard let session = lease else { return }
        activePath = nil; imageURL = nil; target = nil
        do { try await Task.detached(priority: .userInitiated) { try session.finish() }.value }
        catch {
            restorationPending = session.recoveryPending
            lease = nil
            throw error
        }
        restorationPending = session.recoveryPending
        lease = nil
        try requireRestoredBackdrop()
    }

    func recover() async throws {
        guard lease == nil, !transitioning else { return }
        transitioning = true
        var settings: SceneBackdropConfiguration?
        defer {
            // A thrown helper must not leave the UI claiming recovery is done.
            // Missing configuration cannot prove that a journal is safe either.
            restorationPending = settings?.recoveryPending ?? true
            finishTransition()
        }
        do {
            let configured = try configuration()
            settings = configured
            try await Task.detached(priority: .userInitiated) { try SceneBackdropLease.recover(configured) }.value
            issue = nil
        } catch {
            issue = error.localizedDescription
            throw error
        }
    }
}
