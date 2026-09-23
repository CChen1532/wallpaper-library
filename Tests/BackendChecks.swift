import Foundation

@main struct BackendChecks {
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
        if CommandLine.arguments.contains("--live") {
            let backend = PhontoBackend()
            let state = try await backend.state()
            let items = try await backend.library()
            check(!items.isEmpty, "真实素材目录非空")
            check(items.allSatisfy { $0.thumbnail != nil && $0.warning == nil }, "真实素材元数据和缩略图")
            print("LIVE: \(items.count) 个素材，运行=\(state.running)，轮播=\(state.rotating)")
        }
        print("\(count) checks passed")
    }
}
