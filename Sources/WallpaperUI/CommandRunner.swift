import Foundation
import Darwin

struct CommandResult: Sendable {
    let code: Int32
    let text: String
    var errorText = ""
    var message: String { errorText.isEmpty ? text : errorText }
}
protocol CommandExecuting: Sendable {
    func run(_ executable: String, _ args: [String], timeout: Double) async throws -> CommandResult
}
extension CommandExecuting {
    func run(_ executable: String, _ args: [String]) async throws -> CommandResult {
        try await run(executable, args, timeout: 20)
    }
}
enum BackendError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
struct CommandRunner: CommandExecuting {
    func run(_ executable: String, _ args: [String], timeout: Double = 20) async throws -> CommandResult {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let output = directory.appendingPathComponent("stdout")
            let errors = directory.appendingPathComponent("stderr")
            guard FileManager.default.createFile(atPath: output.path, contents: nil),
                  FileManager.default.createFile(atPath: errors.path, contents: nil) else {
                throw BackendError.message("无法创建命令输出缓存")
            }
            let outHandle = try FileHandle(forWritingTo: output)
            defer { try? outHandle.close() }
            let errHandle = try FileHandle(forWritingTo: errors)
            defer { try? errHandle.close() }
            process.standardOutput = outHandle
            process.standardError = errHandle
            try process.run()
            let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
            do {
                while process.isRunning {
                    try Task.checkCancellation()
                    guard ContinuousClock.now < deadline else {
                        throw BackendError.message("操作超时，请刷新确认实际状态。")
                    }
                    try await Task.sleep(for: .milliseconds(40))
                }
            } catch {
                // Only terminate the subprocess launched here, never a phonto service PID.
                await Task.detached(priority: .utility) {
                    if process.isRunning { process.terminate() }
                    for _ in 0..<10 {
                        if !process.isRunning { break }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                }.value
                throw error
            }
            return CommandResult(code: process.terminationStatus, text: try Self.readOutput(output), errorText: try Self.readOutput(errors))
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    private static func readOutput(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let limit = 1_048_576
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw BackendError.message("命令输出超过 1 MB，已停止解析。") }
        return String(decoding: data, as: UTF8.self)
    }
}
