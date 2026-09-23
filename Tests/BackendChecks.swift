import Foundation

@main struct BackendChecks {
    @MainActor
    static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ name: String) {
            guard value else { fatalError("FAIL: \(name)") }
            count += 1; print("PASS: \(name)")
        }
        var state = PlaybackState()
        state.lastPath = "/tmp/中文 空格.mp4"
        check(state.currentPath == nil, "未运行时忽略陈旧路径")
        state.running = true
        check(state.currentPath == state.lastPath, "运行时使用当前路径")
        let path = "/tmp/中文 $(example) 空格.mp4"
        check(try PhontoBackend.arguments(for: .play(path)) == ["start", path], "路径作为单独参数")
        check(try PhontoBackend.arguments(for: .stop) == ["stop"], "停止保留轮播")
        check(try PhontoBackend.arguments(for: .off) == ["off"], "全关命令")
        for action in [Action.rotation(0, "rand"), .rotation(59, "rand"), .rotation(60, "next")] {
            do { _ = try PhontoBackend.arguments(for: action); fatalError("接受无效轮播参数") }
            catch { check(true, "拒绝不支持的轮播参数") }
        }
        var item = Wallpaper(url: URL(fileURLWithPath: "/tmp/a.mp4"))
        item.codec = "h264"; item.width = 4096
        check(!item.decodeWarning, "4096 边界")
        item.width = 4097
        check(item.decodeWarning, "超宽 H264 警告")
        item.codec = "hevc"
        check(!item.decodeWarning, "HEVC 不误报")
        let runner = CommandRunner()
        let echo = try await runner.run("/bin/echo", [path])
        check(echo.code == 0 && echo.text.trimmingCharacters(in: .newlines) == path, "真实进程保留特殊字符")
        let failed = try await runner.run("/usr/bin/false", [])
        check(failed.code != 0, "进程非零退出码")
        do { _ = try await runner.run("/bin/sleep", ["2"], timeout: 0.1); fatalError("超时无效") }
        catch { check(true, "进程超时") }
        let cancelled = Task { try await runner.run("/bin/sleep", ["5"], timeout: 10) }
        try await Task.sleep(for: .milliseconds(80))
        let cancellationStart = ContinuousClock.now
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("取消无效") }
        catch is CancellationError { check(ContinuousClock.now - cancellationStart < .seconds(2), "取消会终止子进程且快速返回") }
        let separated = try await runner.run("/bin/sh", ["-c", "printf 'ok'; printf 'warning' >&2"])
        check(separated.text == "ok" && separated.errorText == "warning", "stdout与stderr分离")
        check(abs(PhontoBackend.frameRate("30000/1001") - 29.970) < 0.001, "分数帧率")
        check(PhontoBackend.frameRate("0/0") == 0 && PhontoBackend.frameRate("NaN/1") == 0, "无效帧率不传播非有限数")

        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("WallpaperUITest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let media = fixture.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let fakeRunner = StateRunner()
        let backend = PhontoBackend(home: fixture, runner: fakeRunner, directoryOverride: media)
        let configDirectory = fixture.appendingPathComponent(".config/phonto")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try Data("60 rand".utf8).write(to: configDirectory.appendingPathComponent("rotate.conf"))
        let agents = fixture.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["StartInterval": 120, "ProgramArguments": ["phonto-wall", "next"]], format: .xml, options: 0)
        try plist.write(to: agents.appendingPathComponent("com.local.phonto-rotate.plist"))
        await fakeRunner.setRegistered(true)
        let mismatched = try await backend.state()
        check(mismatched.rotating && mismatched.interval == 120 && mismatched.mode == "next" && mismatched.notice != nil, "任务配置优先于陈旧轮播意图")
        await fakeRunner.setRegistered(false)
        check(try await backend.state().rotating == false, "存在配置文件不代表轮播运行")
        await fakeRunner.setFailure(true)
        do { _ = try await backend.state(); fatalError("查询失败误报关闭") }
        catch { check(true, "权限错误显示未知而不是关闭") }
        await fakeRunner.setFailure(false)
        check(try await backend.library().isEmpty, "空目录可正常读取")
        let outside = fixture.appendingPathComponent("outside.mp4")
        try Data([1, 2, 3]).write(to: outside)
        do { try await backend.trash(outside); fatalError("允许越界删除") }
        catch { check(FileManager.default.fileExists(atPath: outside.path), "越界删除拒绝且文件保留") }
        let link = media.appendingPathComponent("link.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        do { try backend.validateLibraryFile(link); fatalError("允许符号链接") }
        catch { check(true, "拒绝符号链接素材") }

        let controlled = ControlledBackend()
        let model = LibraryModel(backend: controlled)
        let stalePoll = Task { await model.refreshState() }
        while !(await controlled.hasPendingRead) { await Task.yield() }
        await model.perform(.play("/tmp/new.mp4"))
        await controlled.releaseStaleRead()
        await stalePoll.value
        check(model.state.currentPath == "/tmp/new.mp4", "旧轮询晚返回不会覆盖操作后的状态")
        await model.refreshLibrary()
        model.selected = "/tmp/new.mp4"
        await controlled.clearLibrary()
        await model.refreshLibrary()
        check(model.selected == nil && model.selectedWallpaper == nil, "外部删除后清除失效选择")
        await controlled.setLibraryFailure()
        await model.refreshLibrary()
        check(model.libraryIssue != nil && model.items.isEmpty, "目录读取失败不保留可操作旧卡片")
        await controlled.setSlowOperation()
        let operation = Task { await model.perform(.next) }
        while !model.busy { await Task.yield() }
        await model.perform(.next)
        await operation.value
        check(await controlled.actionCount == 2, "进行中重复操作被拒绝")
        model.state.rotating = true
        model.state.interval = 90
        model.stateIssue = "查询失败"
        check(model.rotationStatusText == "状态未知" && model.rotationIntervalText == "未知", "失败时不展示陈旧轮播状态")
        model.stateIssue = nil
        check(model.rotationStatusText == "已开启" && model.rotationIntervalText == "90 秒", "非整分钟间隔不被截断")
        model.selected = nil
        model.selectNextVideo(in: ["a", "b"], forward: true)
        check(model.selected == "a", "键盘选择起始项")
        model.selectNextVideo(in: ["a", "b"], forward: true)
        model.selectNextVideo(in: ["a", "b"], forward: true)
        check(model.selected == "b", "键盘选择末尾不会越界")
        model.selectNextVideo(in: ["a"], forward: false)
        check(model.selected == "a", "过滤掉选中项后键盘选择有效项")
        model.selectNextVideo(in: [], forward: true)
        check(model.selected == nil, "空搜索结果清除键盘选择")
        if CommandLine.arguments.contains("--live") {
            let backend = PhontoBackend()
            let state = try await backend.state()
            let items = try await backend.library()
            check(!items.isEmpty, "真实素材目录非空")
            check(items.allSatisfy { $0.thumbnail != nil && $0.warning == nil }, "真实素材元数据和缩略图")
            check(items.allSatisfy { $0.fps > 0 && $0.sizeBytes > 0 }, "真实帧率和文件大小")
            let diagnostic = try await backend.diagnostics()
            check(diagnostic.displays.contains("RESOLUTION") && !diagnostic.status.isEmpty, "真实显示器与状态诊断")
            print("LIVE: \(items.count) 个素材，运行=\(state.running)，轮播=\(state.rotating)")
        }
        if CommandLine.arguments.contains("--media") {
            let realRunner = CommandRunner()
            let generator = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/ffmpeg").path
            let sample = fixture.appendingPathComponent("测试 空格.MP4")
            let generated = try await realRunner.run(generator, ["-v", "error", "-f", "lavfi", "-i", "color=c=blue:s=64x64:d=0.2", "-c:v", "libx264", sample.path])
            check(generated.code == 0, "生成独立微型视频fixture")
            let mapped = MediaRunner()
            let mediaBackend = PhontoBackend(home: fixture, runner: mapped, directoryOverride: media)
            check(await mediaBackend.importFiles([sample]).isEmpty, "有效MP4导入")
            let imported = media.appendingPathComponent("测试 空格.mp4")
            check(FileManager.default.fileExists(atPath: imported.path), "大写扩展名导入后标准化为mp4")
            let before = try Data(contentsOf: imported)
            let duplicateProblems = await mediaBackend.importFiles([sample])
            let after = try Data(contentsOf: imported)
            check(duplicateProblems.count == 1 && after == before, "重复导入保留原文件")
            check(await mediaBackend.importFiles([outside]).count == 1, "无效视频不导入")
            let library = try await mediaBackend.library()
            check(library.count == 1 && library[0].thumbnail != nil && library[0].playable, "fixture元数据与缩略图")
            let preview = library[0].thumbnail!
            let modification = try preview.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            _ = try await mediaBackend.library()
            check(try preview.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modification, "再次读取命中预览缓存")
            try Data().write(to: preview)
            _ = try await mediaBackend.library()
            check((try preview.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0, "零字节失败预览可重建")
            try Data([1, 2, 3]).write(to: media.appendingPathComponent("broken.mp4"))
            let brokenLibrary = try await mediaBackend.library()
            check(brokenLibrary.count == 2 && brokenLibrary.first(where: { $0.title == "broken" })?.playable == false, "坏视频被标记不可播放且不影响其他素材")
            check(try FileManager.default.contentsOfDirectory(atPath: media.path).allSatisfy { !$0.hasPrefix(".import-") }, "导入临时文件清理")
            try await backend.trash(imported)
            check(!FileManager.default.fileExists(atPath: imported.path), "独立测试素材成功移入废纸篓")
        }
        print("\(count) checks passed")
    }
}

actor StateRunner: CommandExecuting {
    var registered = false
    var failure = false
    func setRegistered(_ value: Bool) { registered = value }
    func setFailure(_ value: Bool) { failure = value }
    func run(_ executable: String, _ args: [String], timeout: Double) async throws -> CommandResult {
        if executable.hasSuffix("pgrep") { return .init(code: 1, text: "") }
        if failure { return .init(code: 1, text: "", errorText: "Operation not permitted") }
        return .init(code: registered ? 0 : 113, text: registered ? "job" : "", errorText: registered ? "" : "Could not find service")
    }
}
actor ControlledBackend: WallpaperBackend {
    nonisolated let capabilities = BackendCapabilities(name: "test", libraryDirectory: nil)
    var pending: CheckedContinuation<PlaybackState, Never>?
    var hasPendingRead: Bool { pending != nil }
    var firstRead = true
    var value = PlaybackState()
    var list = [Wallpaper(url: URL(fileURLWithPath: "/tmp/new.mp4"))]
    var failLibrary = false
    var slow = false
    var actionCount = 0
    func state() async throws -> PlaybackState {
        if firstRead { firstRead = false; return await withCheckedContinuation { pending = $0 } }
        return value
    }
    func releaseStaleRead() { pending?.resume(returning: PlaybackState()); pending = nil }
    func library() async throws -> [Wallpaper] {
        if failLibrary { throw BackendError.message("fixture权限失败") }
        return list
    }
    func clearLibrary() { list = [] }
    func setLibraryFailure() { failLibrary = true }
    func setSlowOperation() { slow = true }
    func perform(_ action: Action) async throws {
        actionCount += 1
        if slow { try await Task.sleep(for: .milliseconds(100)) }
        value.running = true; value.lastPath = "/tmp/new.mp4"
    }
    func importFiles(_ urls: [URL]) async -> [String] { [] }
    func trash(_ url: URL) async throws {}
    func diagnostics() async throws -> BackendDiagnostics { .init(displays: "test", status: "test") }
}
struct MediaRunner: CommandExecuting {
    func run(_ executable: String, _ args: [String], timeout: Double) async throws -> CommandResult {
        let tool = URL(fileURLWithPath: executable).lastPathComponent
        return try await CommandRunner().run(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/" + tool).path, args, timeout: timeout)
    }
}
