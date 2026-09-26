import Foundation
import Darwin

public enum MirageSceneBridgeError: LocalizedError {
    case invalid(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let detail), .failed(let detail): detail
        }
    }
}

/// A pinned Mirage runtime tree supplies the renderer, shader assets, Vulkan
/// ICD, and dylibs together. The GPL source is the v1.1.4 submodule in ThirdParty.
public struct MirageSceneRuntime: Sendable {
    public let app: URL
    public let executable: URL
    public let assets: URL
    public let icd: URL
    public let frameworks: URL

    public init(app: URL) throws {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let executable = resources.appendingPathComponent("Renderers/SceneWallpaper")
        let assets = resources.appendingPathComponent("assets", isDirectory: true)
        let icd = resources.appendingPathComponent("Renderers/vulkan/icd.d/MoltenVK_icd.json")
        let frameworks = contents.appendingPathComponent("Frameworks", isDirectory: true)
        let vulkanLoader = frameworks.appendingPathComponent("libvulkan.1.dylib")
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: executable.path),
              fm.fileExists(atPath: assets.path), fm.fileExists(atPath: icd.path),
              fm.fileExists(atPath: frameworks.path), fm.fileExists(atPath: vulkanLoader.path) else {
            throw MirageSceneBridgeError.invalid("Mirage Scene 运行包缺少渲染器、assets、MoltenVK 或 Vulkan Loader")
        }
        self.app = app
        self.executable = executable
        self.assets = assets
        self.icd = icd
        self.frameworks = frameworks
    }

    public func trialArguments(scenePackage: URL, displayID: UInt32,
                               durationSeconds: Int = 5, followFocus: Bool = false,
                               horizontalCropPosition: Double = 0.5) throws -> [String] {
        guard displayID != 0 else { throw MirageSceneBridgeError.invalid("显示器 ID 必须非零") }
        guard durationSeconds == 5 || durationSeconds == 60 else {
            throw MirageSceneBridgeError.invalid("仅允许 5 秒或 60 秒的隔离试验")
        }
        guard horizontalCropPosition.isFinite, (0...1).contains(horizontalCropPosition) else {
            throw MirageSceneBridgeError.invalid("横向裁切位置必须在 0 到 1 之间")
        }
        let values = try scenePackage.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard scenePackage.lastPathComponent == "scene.pkg",
              values.isRegularFile == true, values.isSymbolicLink != true,
              let bytes = values.fileSize, bytes > 0 else {
            throw MirageSceneBridgeError.invalid("仅接受非链接且非空的普通 scene.pkg")
        }
        var arguments = ["--display-id", String(displayID), "--fps", "30", "--muted", "--no-spectrum",
                "--control-stdin", "--deferred-show", "--run-seconds", String(durationSeconds + 90),
                assets.path, scenePackage.path]
        if followFocus { arguments.insert("--follow-focus", at: arguments.count - 2) }
        if horizontalCropPosition != 0.5 {
            arguments.insert(contentsOf: ["--position-x", String(horizontalCropPosition)],
                             at: arguments.count - 2)
        }
        return arguments
    }

    /// Continuous app-owned playback. Parent EOF/watchdog and explicit stop own
    /// the lifetime; the development probe's short timeout is not reused here.
    public func playbackArguments(scenePackage: URL, displayID: UInt32, fps: Int = 30,
                                  horizontalCropPosition: Double = 0.5,
                                  mouseEnabled: Bool = true, mouseButtonsEnabled: Bool = true,
                                  inputHz: Int = 60, soundEnabled: Bool = false,
                                  audioResponseEnabled: Bool = false) throws -> [String] {
        guard [30, 60, 120].contains(inputHz) else {
            throw MirageSceneBridgeError.invalid("鼠标采样频率请选择 30、60 或 120 Hz")
        }
        guard [30, 60].contains(fps) else {
            throw MirageSceneBridgeError.invalid("场景帧率请选择 30 或 60 FPS")
        }
        var arguments = try trialArguments(scenePackage: scenePackage, displayID: displayID,
                                           followFocus: true, horizontalCropPosition: horizontalCropPosition)
        if let index = arguments.firstIndex(of: "--run-seconds") {
            arguments.removeSubrange(index...index + 1)
        }
        if let index = arguments.firstIndex(of: "--fps") { arguments[index + 1] = String(fps) }
        if soundEnabled { arguments.removeAll { $0 == "--muted" } }
        if audioResponseEnabled { arguments.removeAll { $0 == "--no-spectrum" } }
        var input = ["--input-hz", String(inputHz)]
        if !mouseEnabled { input.append("--no-mouse") }
        if !mouseButtonsEnabled { input.append("--no-mouse-buttons") }
        arguments.insert(contentsOf: input, at: arguments.count - 2)
        return arguments
    }

    public func environment() -> [String: String] {
        var result = ProcessInfo.processInfo.environment
        result["VK_ICD_FILENAMES"] = icd.path
        result["VK_DRIVER_FILES"] = icd.path
        let existing = result["DYLD_FALLBACK_LIBRARY_PATH"]
        result["DYLD_FALLBACK_LIBRARY_PATH"] = frameworks.path + (existing.map { ":" + $0 } ?? "")
        let fontConfig = app.appendingPathComponent("Contents/Resources/fonts/fonts.conf")
        if FileManager.default.fileExists(atPath: fontConfig.path) {
            result["FONTCONFIG_FILE"] = fontConfig.path
        }
        return result
    }
}

/// Only manages a child that this object launched. No phonto or unrelated
/// process is signalled. The renderer starts transparent and is revealed only
/// after scene readiness plus a first presented frame are observed.
public final class MirageSceneChild: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let condition = NSCondition()
    private var pending = Data()
    private var observed: Set<String> = []
    private var snapshotResponses: [String: Bool] = [:]
    private var lastMovedDisplayID: UInt32?
    private var exitCode: Int32?
    private var errorTail = ""
    private var started = false

    public init(executable: URL, arguments: [String], environment: [String: String]? = nil) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    public func start() throws {
        condition.lock()
        guard !started else {
            condition.unlock()
            throw MirageSceneBridgeError.invalid("渲染进程只能启动一次")
        }
        // A renderer may close stdin while Process still reports it running.
        // EPIPE must reach Swift as an error instead of terminating the host.
        guard Darwin.fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            condition.unlock()
            throw MirageSceneBridgeError.failed("无法为渲染器控制管道禁用 SIGPIPE")
        }
        started = true
        condition.unlock()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeError(handle.availableData)
        }
        process.terminationHandler = { [weak self] child in
            self?.finished(code: child.terminationStatus)
        }
        do {
            try process.run()
            try? input.fileHandleForReading.close()
        }
        catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            finished(code: -1)
            throw error
        }
    }

    public func wait(for event: String, timeout: TimeInterval) throws {
        guard timeout.isFinite, timeout > 0, timeout <= 60 else {
            throw MirageSceneBridgeError.invalid("事件等待时间无效")
        }
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !observed.contains(event) {
            if observed.contains("activation-failed") {
                throw MirageSceneBridgeError.failed("Mirage Scene 显示激活失败：\(errorTail)")
            }
            if let exitCode {
                throw MirageSceneBridgeError.failed("Mirage Scene 提前退出（\(exitCode)）：\(errorTail)")
            }
            if !condition.wait(until: deadline) {
                throw MirageSceneBridgeError.failed("等待 Mirage Scene 事件超时：\(event)；\(errorTail)")
            }
        }
    }

    public func send(_ command: String) throws {
        guard ["activate", "deactivate", "quit"].contains(command), process.isRunning else {
            throw MirageSceneBridgeError.invalid("命令无效或渲染进程已退出")
        }
        let data = Data("{\"cmd\":\"\(command)\"}\n".utf8)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    public func move(to displayID: UInt32) throws {
        guard displayID != 0, process.isRunning else {
            throw MirageSceneBridgeError.invalid("目标显示器无效或渲染进程已退出")
        }
        condition.lock()
        lastMovedDisplayID = nil
        observed.remove("display-move-failed")
        condition.unlock()
        let data = Data("{\"cmd\":\"moveDisplay\",\"displayID\":\(displayID)}\n".utf8)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    /// Nonblocking status for a cancellable async host. All process commands
    /// still belong to a single worker; the reader callbacks only record events.
    public func eventReceived(_ event: String) throws -> Bool {
        condition.lock(); defer { condition.unlock() }
        try checkLiveEventState()
        return observed.contains(event)
    }

    public func moveAcknowledged(to displayID: UInt32) throws -> Bool {
        condition.lock(); defer { condition.unlock() }
        try checkLiveEventState()
        if observed.contains("display-move-failed") {
            throw MirageSceneBridgeError.failed("渲染窗口跨屏移动失败：\(errorTail)")
        }
        return lastMovedDisplayID == displayID
    }

    private func checkLiveEventState() throws {
        if let exitCode {
            throw MirageSceneBridgeError.failed("场景渲染器已退出（\(exitCode)）：\(errorTail)")
        }
        if observed.contains("activation-failed") {
            throw MirageSceneBridgeError.failed("场景显示失败：\(errorTail)")
        }
    }

    /// Captures one renderer-owned frame without ordering the transparent
    /// desktop window into view. The caller supplies a new file path and owns
    /// the image after the renderer acknowledges the matching token.
    public func snapshot(to url: URL, timeout: TimeInterval = 8,
                         token: String = UUID().uuidString) throws {
        guard timeout.isFinite, timeout > 0, timeout <= 15,
              !token.isEmpty, token.count <= 64,
              token.utf8.allSatisfy({ $0 == 45 || (48...57).contains($0) ||
                                     (65...90).contains($0) || (97...122).contains($0) }),
              url.isFileURL, process.isRunning else {
            throw MirageSceneBridgeError.invalid("静帧请求无效或渲染进程已退出")
        }
        let message: [String: String] = ["cmd": "snapshot", "path": url.path, "token": token]
        let data = try JSONSerialization.data(withJSONObject: message)
        condition.lock()
        snapshotResponses.removeValue(forKey: token)
        condition.unlock()
        try input.fileHandleForWriting.write(contentsOf: data + Data([10]))

        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while snapshotResponses[token] == nil {
            if let exitCode {
                throw MirageSceneBridgeError.failed("渲染器在静帧请求期间退出（\(exitCode)）：\(errorTail)")
            }
            if !condition.wait(until: deadline) {
                throw MirageSceneBridgeError.failed("等待 Mirage Scene 静帧超时：\(errorTail)")
            }
        }
        let ok = snapshotResponses.removeValue(forKey: token) == true
        guard ok else { throw MirageSceneBridgeError.failed("Mirage Scene 静帧导出失败") }
    }

    public func waitForMove(to displayID: UInt32, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while lastMovedDisplayID != displayID {
            if observed.contains("display-move-failed") {
                throw MirageSceneBridgeError.failed("渲染窗口跨屏移动失败：\(errorTail)")
            }
            if let exitCode {
                throw MirageSceneBridgeError.failed("渲染器在跨屏移动时退出（\(exitCode)）：\(errorTail)")
            }
            if !condition.wait(until: deadline) {
                throw MirageSceneBridgeError.failed("等待渲染窗口跨屏移动超时：\(displayID)")
            }
        }
    }

    public func stop() {
        guard started else { return }
        if process.isRunning {
            try? send("deactivate")
            try? wait(for: "deactivated", timeout: 1.5)
            try? send("quit")
            try? input.fileHandleForWriting.close()
        }
        if !waitForExit(seconds: 3), process.isRunning {
            process.terminate()
        }
        if !waitForExit(seconds: 2), process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            _ = waitForExit(seconds: 2)
        }
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
    }

    deinit { stop() }

    public var terminationStatus: Int32? {
        condition.lock(); defer { condition.unlock() }
        return exitCode
    }

    public var processIdentifier: Int32 { process.processIdentifier }

    private func waitForExit(seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        condition.lock()
        defer { condition.unlock() }
        while exitCode == nil {
            if !condition.wait(until: deadline) { return false }
        }
        return true
    }

    private func finished(code: Int32) {
        condition.lock()
        exitCode = code
        condition.broadcast()
        condition.unlock()
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else {
            output.fileHandleForReading.readabilityHandler = nil
            return
        }
        condition.lock()
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let event = object["event"] as? String, event.count <= 80 {
                observed.insert(event)
                if event == "display-moved", let number = object["display_id"] as? NSNumber {
                    lastMovedDisplayID = number.uint32Value
                }
                if event == "snapshot-done", let token = object["token"] as? String,
                   let ok = object["ok"] as? Bool {
                    snapshotResponses[token] = ok
                }
                condition.broadcast()
            }
        }
        if pending.count > 1_048_576 { pending.removeAll() }
        condition.unlock()
    }

    private func consumeError(_ data: Data) {
        guard !data.isEmpty else {
            errors.fileHandleForReading.readabilityHandler = nil
            return
        }
        condition.lock()
        errorTail += String(decoding: data, as: UTF8.self)
        if errorTail.utf8.count > 8192 { errorTail = String(errorTail.suffix(4096)) }
        condition.unlock()
    }
}
