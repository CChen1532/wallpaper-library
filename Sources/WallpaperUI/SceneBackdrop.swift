import Foundation

struct SceneBackdropConfiguration: Sendable {
    static let preferenceKey = "sceneAutomaticBackdrop"
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: preferenceKey) as? Bool ?? false
    }
    let helper: URL
    let inventory: URL
    let state: URL
    var sourcePackage: URL?

    static func bundled() throws -> Self {
        let resources = (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appendingPathComponent("WallpaperSwitch", isDirectory: true)
        let helper = resources.appendingPathComponent("wallpaper-switch.py")
        let inventory = resources.appendingPathComponent("space-inventory")
        guard FileManager.default.isReadableFile(atPath: helper.path),
              FileManager.default.isExecutableFile(atPath: inventory.path) else {
            throw BackendError.message("过渡底图组件缺失，请使用完整打包的应用")
        }
        let state = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WallpaperUI/SpaceBackdrop", isDirectory: true)
        return Self(helper: helper, inventory: inventory, state: state)
    }

    var recoveryPending: Bool {
        let journal = state.appendingPathComponent("session.plist")
        guard FileManager.default.fileExists(atPath: journal.path) else { return false }
        guard let data = try? Data(contentsOf: journal),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return true }
        return value["state"] as? String != "restored"
    }
}

struct SpaceBackdropCompatibilityFailure: LocalizedError, Sendable {
    let reason: String
    var errorDescription: String? { reason }
}

/// The helper checks the supported macOS build and private WallpaperAgent
/// structure without changing the desktop. It checks again inside the lease
/// immediately before the first system write; restore never uses this gate.
enum SpaceBackdropCompatibility {
    static func check(_ settings: SceneBackdropConfiguration, displayID: UInt32) async throws {
        let result = try await CommandRunner().run("/usr/bin/python3", [
            settings.helper.path, "--state-dir", settings.state.path,
            "--inventory", settings.inventory.path,
            "check-compatibility", "--display", String(displayID)
        ], timeout: 10)
        if result.code == 3 {
            throw SpaceBackdropCompatibilityFailure(reason: result.message)
        }
        guard result.code == 0, result.text.contains("WALLPAPER_COMPATIBILITY_OK") else {
            throw BackendError.message(result.message.isEmpty
                ? "无法完成系统墙纸兼容性检查" : result.message)
        }
    }
}

protocol SceneBackdropControlling: AnyObject, Sendable {
    var recoveryPending: Bool { get }
    var previewURL: URL? { get }
    var registrationURL: URL? { get }
    func activate(displayID: UInt32, capture: (URL) throws -> Void) throws
    func checkHealth() throws
    func finish() throws
}

extension SceneBackdropControlling {
    var previewURL: URL? { nil }
    var registrationURL: URL? { nil }
}

/// A worker owns this object. Only the bounded output buffer is touched by the
/// pipe callback. Keeping stdin open grants a lease; EOF requests restoration.
final class SceneBackdropLease: SceneBackdropControlling, @unchecked Sendable {
    private let configuration: SceneBackdropConfiguration
    private(set) var previewURL: URL?
    private(set) var registrationURL: URL?
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private let lock = NSLock()
    private var messages = Data()

    init(configuration: SceneBackdropConfiguration) { self.configuration = configuration }
    var recoveryPending: Bool { configuration.recoveryPending || process?.isRunning == true }

    private var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: messages, as: UTF8.self)
    }
    private func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        messages.append(data)
        if messages.count > 16_384 { messages = Data(messages.suffix(16_384)) }
    }
    private func launch(_ arguments: [String]) throws {
        guard process == nil else { throw BackendError.message("上一次底图恢复尚未完成") }
        lock.lock(); messages.removeAll(); lock.unlock()
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = [configuration.helper.path, "--state-dir", configuration.state.path,
                           "--inventory", configuration.inventory.path] + arguments
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stdout
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty { self?.append(data) }
        }
        do { try child.run() }
        catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        // Close our copy of the read end: the helper must see EOF when the UI
        // closes its writer or dies. No second writer is retained elsewhere.
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        process = child; input = stdin; output = stdout
    }

    func activate(displayID: UInt32, capture: (URL) throws -> Void) throws {
        guard let package = configuration.sourcePackage else {
            throw BackendError.message("缺少当前壁纸身份，拒绝使用其他壁纸底图")
        }
        let image = try SceneBackdropCapture.capture(package: package, state: configuration.state, render: capture)
        try activatePreparedImage(displayID: displayID, image: image)
    }

    /// Video frames are decoded ahead of time and independently validated.
    /// The same journalled lease owns both Scene and video desktop pictures.
    func activatePreparedImage(displayID: UInt32, image: URL) throws {
        guard FileManager.default.isReadableFile(atPath: image.path) else {
            throw BackendError.message("当前壁纸静帧不可读取")
        }
        try launch(["lease", image.path, "--spaces", "all", "--display", String(displayID)])
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while true {
            try Task.checkCancellation()
            try checkHealth()
            if text.contains("BACKDROP_READY\n") {
                let journal = configuration.state.appendingPathComponent("session.plist")
                let data = try Data(contentsOf: journal)
                guard let session = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let path = session["image"] as? String else {
                    throw BackendError.message("底图恢复记录没有当前图片路径")
                }
                registrationURL = URL(fileURLWithPath: path)
                previewURL = image
                return
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw BackendError.message("自动底图准备超时")
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
    }

    func checkHealth() throws {
        guard let process, process.isRunning else {
            if process?.terminationStatus == 3 {
                throw SpaceBackdropCompatibilityFailure(reason: text)
            }
            throw BackendError.message("自动底图进程已退出。\(text)")
        }
    }

    func finish() throws {
        guard let child = process else { return }
        try? input?.fileHandleForWriting.close()
        // Not cancellation-sensitive: restoration must finish even when the
        // player task was cancelled to stop, switch, sleep or quit.
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.025)
        }
        guard !child.isRunning else {
            child.terminate() // Python handles TERM with the same rollback.
            throw BackendError.message("底图恢复仍在进行，恢复记录已保留；请稍后重试")
        }
        output?.fileHandleForReading.readabilityHandler = nil
        if let data = try? output?.fileHandleForReading.readToEnd() { append(data) }
        process = nil; input = nil; output = nil
        guard !configuration.recoveryPending, child.terminationStatus == 0 else {
            throw BackendError.message("自动底图操作未完成。\(text)")
        }
    }

    static func recover(_ configuration: SceneBackdropConfiguration) throws {
        guard configuration.recoveryPending else { return }
        let session = SceneBackdropLease(configuration: configuration)
        try session.launch(["restore"])
        try session.finish()
    }

    deinit {
        try? input?.fileHandleForWriting.close()
        output?.fileHandleForReading.readabilityHandler = nil
    }
}
