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

/// A pinned Mirage.app bundle supplies the renderer, shader assets, Vulkan ICD,
/// and dylibs together. The GPL source is the v1.1.4 submodule in ThirdParty.
public struct MirageSceneRuntime {
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
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: executable.path),
              fm.fileExists(atPath: assets.path), fm.fileExists(atPath: icd.path),
              fm.fileExists(atPath: frameworks.path) else {
            throw MirageSceneBridgeError.invalid("Mirage Scene 运行包缺少渲染器、assets、MoltenVK 或 Frameworks")
        }
        self.app = app
        self.executable = executable
        self.assets = assets
        self.icd = icd
        self.frameworks = frameworks
    }

    public func trialArguments(scenePackage: URL, displayID: UInt32) throws -> [String] {
        guard displayID != 0 else { throw MirageSceneBridgeError.invalid("显示器 ID 必须非零") }
        let values = try scenePackage.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard scenePackage.lastPathComponent == "scene.pkg",
              values.isRegularFile == true, values.isSymbolicLink != true,
              let bytes = values.fileSize, bytes > 0, bytes <= 256 * 1024 * 1024 else {
            throw MirageSceneBridgeError.invalid("仅接受不超过 256 MiB 的普通 scene.pkg")
        }
        return ["--display-id", String(displayID), "--fps", "30", "--muted", "--no-spectrum",
                "--control-stdin", "--deferred-show", "--run-seconds", "90",
                assets.path, scenePackage.path]
    }

    public func environment() -> [String: String] {
        var result = ProcessInfo.processInfo.environment
        result["VK_ICD_FILENAMES"] = icd.path
        result["VK_DRIVER_FILES"] = icd.path
        let existing = result["DYLD_FALLBACK_LIBRARY_PATH"]
        result["DYLD_FALLBACK_LIBRARY_PATH"] = frameworks.path + (existing.map { ":" + $0 } ?? "")
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
        do { try process.run() }
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
