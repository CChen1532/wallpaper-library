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
    var fps = 0.0
    var sizeBytes: Int64 = 0
    var playable = true
    var thumbnail: URL?
    var warning: String?
    var decodeWarning: Bool { codec == "h264" && width > 4096 }
}
struct PlaybackState: Sendable {
    var running = false
    var lastPath: String?
    var currentPath: String? { running ? lastPath : nil }
    var rotating = false
    var interval: Int?
    var mode: String?
    var notice: String?
}
struct BackendCapabilities: Sendable {
    var name: String
    var libraryDirectory: URL?
    var rotationModes: [String] = []
    var canImport = false
    var canTrash = false
}
struct BackendDiagnostics: Sendable {
    var displays: String
    var status: String
}
enum Action: Sendable { case play(String), next, previous, random, stop, off, rotation(Int, String), stopRotation }
protocol WallpaperBackend: Sendable {
    var capabilities: BackendCapabilities { get }
    func library() async throws -> [Wallpaper]
    func state() async throws -> PlaybackState
    func perform(_ action: Action) async throws
    func importFiles(_ urls: [URL]) async -> [String]
    func trash(_ url: URL) async throws
    func diagnostics() async throws -> BackendDiagnostics
}
struct PhontoBackend: WallpaperBackend {
    var home = FileManager.default.homeDirectoryForCurrentUser
    var runner: any CommandExecuting = CommandRunner()
    var directoryOverride: URL?
    var directory: URL { directoryOverride ?? home.appendingPathComponent("Movies/Wallpapers") }
    var capabilities: BackendCapabilities { .init(name: "phonto", libraryDirectory: directory, rotationModes: ["rand"], canImport: true, canTrash: true) }
    var command: String { home.appendingPathComponent(".local/bin/phonto-wall").path }
    func library() async throws -> [Wallpaper] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]).filter { $0.pathExtension == "mp4" }.sorted { $0.path < $1.path }
        let cache = home.appendingPathComponent("Library/Caches/WallpaperUI/Thumbnails")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var results: [Wallpaper] = []
        for url in urls {
            try Task.checkCancellation()
            var item = Wallpaper(url: url)
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                item.sizeBytes = Int64(values.fileSize ?? 0)
                let result = try await runner.run(home.appendingPathComponent(".local/bin/ffprobe").path, ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name,width,height,avg_frame_rate", "-show_entries", "format=duration", "-of", "json", url.path])
                guard result.code == 0 else { throw BackendError.message(result.message) }
                let probe = try JSONDecoder().decode(Probe.self, from: Data(result.text.utf8))
                guard let stream = probe.streams.first else { throw BackendError.message("未找到视频轨道") }
                item.width = stream.width ?? 0; item.height = stream.height ?? 0
                item.codec = stream.codec_name ?? ""
                let duration = Double(probe.format?.duration ?? "") ?? 0
                item.duration = duration.isFinite && duration >= 0 ? duration : 0
                item.fps = Self.frameRate(stream.avg_frame_rate)
                let key = "\(url.path)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
                let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
                let target = cache.appendingPathComponent(hash + ".jpg")
                if (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 == 0 {
                    let temporary = cache.appendingPathComponent(UUID().uuidString + ".jpg")
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    let generated = try await runner.run(home.appendingPathComponent(".local/bin/ffmpeg").path, ["-v", "error", "-y", "-ss", "0", "-i", url.path, "-frames:v", "1", "-vf", "scale=640:-2", temporary.path])
                    guard generated.code == 0, (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 > 0 else { throw BackendError.message("预览生成失败。" + generated.message) }
                    let data = try Data(contentsOf: temporary)
                    try data.write(to: target, options: .atomic)
                }
                item.thumbnail = target
            } catch is CancellationError { throw CancellationError() }
            catch { item.warning = error.localizedDescription; item.playable = item.width > 0 && item.height > 0 }
            results.append(item)
        }
        return results
    }
    func state() async throws -> PlaybackState {
        var state = PlaybackState()
        let running = try await runner.run("/usr/bin/pgrep", ["-x", "phonto"])
        guard running.code == 0 || running.code == 1 else { throw BackendError.message(running.message) }
        state.running = running.code == 0
        state.lastPath = (try? String(contentsOf: home.appendingPathComponent(".cache/phonto/current"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rotate = try await runner.run("/bin/launchctl", ["print", "gui/\(getuid())/com.local.phonto-rotate"])
        guard rotate.code == 0 || rotate.message.contains("Could not find service") || rotate.message.contains("Could not find specified service") else {
            throw BackendError.message("无法确认轮播状态。" + rotate.message)
        }
        state.rotating = rotate.code == 0
        if let conf = try? String(contentsOf: home.appendingPathComponent(".config/phonto/rotate.conf"), encoding: .utf8) {
            let fields = conf.split(whereSeparator: { $0.isWhitespace })
            if fields.count == 2, let seconds = Int(fields[0]), seconds > 0, ["rand", "next", "prev"].contains(String(fields[1])) {
                state.interval = seconds; state.mode = String(fields[1])
            }
        }
        if state.rotating {
            let plistURL = home.appendingPathComponent("Library/LaunchAgents/com.local.phonto-rotate.plist")
            if let data = try? Data(contentsOf: plistURL), let actual = Self.rotationConfiguration(data) {
                if state.interval != actual.0 || state.mode != actual.1 { state.notice = "轮播意图记录与任务配置不一致，显示任务配置。" }
                state.interval = actual.0; state.mode = actual.1
            } else {
                state.interval = nil; state.mode = nil
                state.notice = "轮播已注册，但无法读取任务配置，请重新应用设置。"
            }
        }
        return state
    }
    static func frameRate(_ text: String?) -> Double {
        let parts = (text ?? "").split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > 0 else { return 0 }
        let value = parts[0] / parts[1]
        return value.isFinite && value >= 0 ? value : 0
    }
    static func rotationConfiguration(_ data: Data) -> (Int, String)? {
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let interval = plist["StartInterval"] as? Int, interval >= 60,
              let args = plist["ProgramArguments"] as? [String], let mode = args.last,
              ["rand", "next", "prev"].contains(mode) else { return nil }
        return (interval, mode)
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
        if case .play(let path) = action { try validateLibraryFile(URL(fileURLWithPath: path)) }
        let result = try await runner.run(command, Self.arguments(for: action), timeout: 30)
        guard result.code == 0, !result.text.contains("❌") else { throw BackendError.message(result.message.isEmpty ? "控制失败（\(result.code)）" : result.message) }
        let actual = try await state()
        switch action {
        case .play(let path):
            guard actual.currentPath == path else { throw BackendError.message("未确认壁纸切换成功。\n" + result.text) }
        case .stop:
            guard !actual.running else { throw BackendError.message("壁纸仍在运行，请刷新后重试。") }
        case .off:
            guard !actual.running && !actual.rotating else { throw BackendError.message("尚未完全关闭，请刷新后重试。") }
        case .rotation(let interval, let mode):
            guard actual.rotating, actual.interval == interval, actual.mode == mode else { throw BackendError.message("轮播任务配置与请求不一致，请刷新后重试。") }
        case .stopRotation:
            guard !actual.rotating else { throw BackendError.message("轮播任务仍然存在。") }
        case .next, .previous, .random:
            guard actual.running, let path = actual.currentPath, FileManager.default.fileExists(atPath: path) else { throw BackendError.message("切换后未确认正在播放的素材。") }
        }
    }
    func validateLibraryFile(_ url: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { throw BackendError.message("素材必须位于壁纸目录中。") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard url.pathExtension == "mp4", values.isRegularFile == true, values.isSymbolicLink != true else { throw BackendError.message("请选择素材目录中的 MP4 普通文件。") }
    }
    func importFiles(_ urls: [URL]) async -> [String] {
        var problems: [String] = []
        for source in urls {
            do {
                try Task.checkCancellation()
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard source.pathExtension.lowercased() == "mp4", values.isRegularFile == true, values.isSymbolicLink != true else { throw BackendError.message("仅支持 MP4 普通文件") }
                let probe = try await runner.run(home.appendingPathComponent(".local/bin/ffprobe").path, ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "json", source.path])
                guard probe.code == 0, let parsed = try? JSONDecoder().decode(Probe.self, from: Data(probe.text.utf8)), let first = parsed.streams.first, (first.width ?? 0) > 0 else { throw BackendError.message("视频无法读取，未导入") }
                // The CLI glob is lowercase *.mp4; normalize imported extensions to match it.
                let destination = directory.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".mp4")
                guard !FileManager.default.fileExists(atPath: destination.path) else { throw BackendError.message("同名文件已存在，已跳过") }
                let staged = directory.appendingPathComponent(".import-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: staged) }
                try await Task.detached(priority: .utility) { try FileManager.default.copyItem(at: source, to: staged) }.value
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: staged, to: destination)
            } catch { problems.append(source.lastPathComponent + ": " + error.localizedDescription) }
        }
        return problems
    }
    func trash(_ url: URL) async throws {
        try validateLibraryFile(url)
        let actual = try await state()
        if actual.currentPath == url.path || actual.rotating { try await perform(.off) }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
    func diagnostics() async throws -> BackendDiagnostics {
        let displays = try await runner.run(home.appendingPathComponent(".local/bin/phonto").path, ["displays"])
        let status = try await runner.run(command, ["status"])
        guard displays.code == 0, status.code == 0 else { throw BackendError.message(displays.message + "\n" + status.message) }
        return BackendDiagnostics(displays: displays.text, status: status.text)
    }
}
private struct Probe: Decodable {
    struct Stream: Decodable { var width: Int?; var height: Int?; var codec_name: String?; var avg_frame_rate: String? }
    struct Format: Decodable { var duration: String? }
    var streams: [Stream]; var format: Format?
}
