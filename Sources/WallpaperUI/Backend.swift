import Foundation
import CryptoKit

struct Wallpaper: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    var title: String { url.deletingPathExtension().lastPathComponent }
    var backend = "phonto"
    var kind = "video"
    var width = 0
    var height = 0
    var codec = ""
    var duration = 0.0
    var thumbnail: URL?
    var warning: String?
    var decodeWarning: Bool { codec == "h264" && width > 4096 }
}
struct PlaybackState: Sendable {
    var running = false
    var lastPath: String?
    var currentPath: String? { running ? lastPath : nil }
    var rotating = false
    var interval = 3600
    var mode = "rand"
}
enum Action: Sendable { case play(String), next, previous, random, stop, off, rotation(Int, String), stopRotation }
protocol WallpaperBackend: Sendable {
    func library() async throws -> [Wallpaper]
    func state() async throws -> PlaybackState
    func perform(_ action: Action) async throws
}
struct CommandResult: Sendable { let code: Int32; let text: String }
enum BackendError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
struct CommandRunner: Sendable {
    func run(_ executable: String, _ args: [String], timeout: Double = 20) async throws -> CommandResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            // A temporary output file avoids full pipe buffers blocking the child.
            let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            FileManager.default.createFile(atPath: output.path, contents: nil)
            defer { try? FileManager.default.removeItem(at: output) }
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if Date() > deadline {
                    process.terminate()
                    throw BackendError.message("操作超时，请刷新确认实际状态。")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            return CommandResult(code: process.terminationStatus, text: (try? String(contentsOf: output, encoding: .utf8)) ?? "")
        }.value
    }
}
struct PhontoBackend: WallpaperBackend {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let runner = CommandRunner()
    var directory: URL { home.appendingPathComponent("Movies/Wallpapers") }
    var command: String { home.appendingPathComponent(".local/bin/phonto-wall").path }
    func library() async throws -> [Wallpaper] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]).filter { $0.pathExtension.lowercased() == "mp4" }.sorted { $0.path < $1.path }
        let cache = home.appendingPathComponent("Library/Caches/WallpaperUI/Thumbnails")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var results: [Wallpaper] = []
        for url in urls {
            var item = Wallpaper(url: url)
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                let result = try await runner.run(home.appendingPathComponent(".local/bin/ffprobe").path, ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name,width,height", "-show_entries", "format=duration", "-of", "json", url.path])
                guard result.code == 0 else { throw BackendError.message(result.text) }
                let probe = try JSONDecoder().decode(Probe.self, from: Data(result.text.utf8))
                guard let stream = probe.streams.first else { throw BackendError.message("未找到视频轨道") }
                item.width = stream.width ?? 0; item.height = stream.height ?? 0
                item.codec = stream.codec_name ?? ""; item.duration = Double(probe.format?.duration ?? "") ?? 0
                let key = "\(url.path)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
                let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
                let target = cache.appendingPathComponent(hash + ".jpg")
                if !FileManager.default.fileExists(atPath: target.path) {
                    let generated = try await runner.run(home.appendingPathComponent(".local/bin/ffmpeg").path, ["-v", "error", "-y", "-ss", "0", "-i", url.path, "-frames:v", "1", "-vf", "scale=640:-2", target.path])
                    guard generated.code == 0 else { throw BackendError.message(generated.text) }
                }
                item.thumbnail = target
            } catch { item.warning = error.localizedDescription }
            results.append(item)
        }
        return results
    }
    func state() async throws -> PlaybackState {
        var state = PlaybackState()
        let running = try await runner.run("/usr/bin/pgrep", ["-x", "phonto"])
        guard running.code == 0 || running.code == 1 else { throw BackendError.message(running.text) }
        state.running = running.code == 0
        state.lastPath = (try? String(contentsOf: home.appendingPathComponent(".cache/phonto/current"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rotate = try await runner.run("/bin/launchctl", ["print", "gui/\(getuid())/com.local.phonto-rotate"])
        state.rotating = rotate.code == 0
        if let conf = try? String(contentsOf: home.appendingPathComponent(".config/phonto/rotate.conf"), encoding: .utf8) {
            let fields = conf.split(whereSeparator: { $0.isWhitespace })
            if fields.count == 2, let seconds = Int(fields[0]), seconds > 0, ["rand", "next", "prev"].contains(String(fields[1])) {
                state.interval = seconds; state.mode = String(fields[1])
            }
        }
        return state
    }
    static func arguments(for action: Action) throws -> [String] {
        switch action {
        case .play(let path): return ["start", path]
        case .next: return ["next"]
        case .previous: return ["prev"]
        case .random: return ["rand"]
        case .stop: return ["stop"]
        case .off: return ["off"]
        case .stopRotation: return ["rotate", "off"]
        case .rotation(let interval, let mode):
            guard interval >= 60, mode == "rand" else { throw BackendError.message("当前控制脚本支持至少 60 秒的随机轮播。") }
            return ["rotate", "on", String(interval), mode]
        }
    }
    func perform(_ action: Action) async throws {
        let result = try await runner.run(command, Self.arguments(for: action), timeout: 30)
        guard result.code == 0 else { throw BackendError.message(result.text.isEmpty ? "控制失败（\(result.code)）" : result.text) }
        let actual = try await state()
        switch action {
        case .play(let path):
            guard actual.currentPath == path else { throw BackendError.message("未确认壁纸切换成功。\n" + result.text) }
        case .stop:
            guard !actual.running else { throw BackendError.message("壁纸仍在运行，请刷新后重试。") }
        case .off:
            guard !actual.running && !actual.rotating else { throw BackendError.message("尚未完全关闭，请刷新后重试。") }
        case .rotation:
            guard actual.rotating else { throw BackendError.message("轮播任务未启动。") }
        case .stopRotation:
            guard !actual.rotating else { throw BackendError.message("轮播任务仍然存在。") }
        default: break
        }
    }
}
private struct Probe: Decodable {
    struct Stream: Decodable { var width: Int?; var height: Int?; var codec_name: String? }
    struct Format: Decodable { var duration: String? }
    var streams: [Stream]; var format: Format?
}
