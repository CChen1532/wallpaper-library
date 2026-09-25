import Foundation
import Darwin

@main struct ScenePlaybackChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ name: String) {
            precondition(value, "FAIL: " + name)
            count += 1
            print("PASS: " + name)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scene-player-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("renderer.sh")
        try #"""
        log="$1"
        mode="$2"
        printf '%s\n' "pid=$$" >> "$log"
        if [ "$mode" = stubborn ]; then trap '' TERM; fi
        if [ "$mode" != stalled ]; then
          printf '%s\n' '{"event":"scene-ready"}' '{"event":"first-frame-presented"}'
        fi
        while IFS= read -r command; do
          printf '%s\n' "$command" >> "$log"
          case "$command" in
            '{"cmd":"activate"}')
              if [ "$mode" = crash ]; then exit 7; fi
              printf '%s\n' '{"event":"activated"}' ;;
            '{"cmd":"deactivate"}') printf '%s\n' '{"event":"deactivated"}' ;;
            '{"cmd":"moveDisplay","displayID":3}') printf '%s\n' '{"event":"display-moved","display_id":3}' ;;
            '{"cmd":"moveDisplay","displayID":1}') printf '%s\n' '{"event":"display-moved","display_id":1}' ;;
            '{"cmd":"quit"}') if [ "$mode" = stubborn ]; then exec /bin/sleep 30; else exit 0; fi ;;
          esac
        done
        """#.write(to: script, atomically: true, encoding: .utf8)

        func configuration(_ name: String, mode: String = "normal") -> SceneLaunchConfiguration {
            .init(executable: URL(fileURLWithPath: "/bin/sh"),
                  arguments: [script.path, root.appendingPathComponent(name + ".log").path, mode],
                  environment: nil, package: root.appendingPathComponent(name + "/scene.pkg"),
                  title: name, displayID: 1)
        }
        func log(_ name: String) -> String {
            (try? String(contentsOf: root.appendingPathComponent(name + ".log"), encoding: .utf8)) ?? ""
        }
        func hasLivePID(_ name: String) -> Bool {
            guard let line = log(name).split(separator: "\n").first,
                  let pid = Int32(line.replacingOccurrences(of: "pid=", with: "")) else { return false }
            return Darwin.kill(pid, 0) == 0
        }

        let player = ScenePlayer(focusProvider: { 1 })
        try player.start(configuration("cancel", mode: "stalled"))
        do { try player.start(configuration("duplicate")); preconditionFailure("duplicate accepted") }
        catch { check(true, "重复开始不创建第二个渲染器") }
        try await wait { !log("cancel").isEmpty }
        let cancelStart = ContinuousClock.now
        await player.stop()
        check(player.phase == .stopped && !player.isActive && !hasLivePID("cancel"), "就绪前取消会清理拥有的进程")
        check(!log("cancel").contains("\"cmd\":\"activate\"") && ContinuousClock.now - cancelStart < .seconds(2), "准备中取消不会晚激活且快速返回")
        check(log("duplicate").isEmpty, "重复播放没有产生子进程")

        let focus = FocusFixture()
        let following = ScenePlayer(focusProvider: { focus.displayID })
        try following.start(configuration("follow"))
        try await wait { following.phase == .playing }
        focus.displayID = 3
        try await Task.sleep(for: .milliseconds(700))
        check(following.displayID == 1, "新焦点不足1.5秒时旧屏继续播放")
        try await wait { following.displayID == 3 }
        focus.displayID = 1
        await following.stop()
        check(!hasLivePID("follow") && !log("follow").contains("displayID\":1"), "停止取消尚未完成的焦点交接")

        try player.start(configuration("crash", mode: "crash"))
        try await wait { player.phase == .failed }
        check(player.error != nil && !player.isActive && !hasLivePID("crash"), "异常退出显示错误并清理状态")

        let coordinated = ScenePlayer(focusProvider: { 1 })
        let backend = SceneTestBackend()
        let model = LibraryModel(backend: backend, scenePlayer: coordinated,
                                 sceneRuntimeURL: root.appendingPathComponent("missing-runtime"))
        await model.playScene(root: root, name: "../outside", title: "bad", expectedBytes: 1, fps: 30, cropMode: "auto")
        check(await backend.actions.isEmpty && model.error != nil, "输入预检失败不停止现有视频")
        await backend.setFailOff(true)
        await model.playPreparedScene(configuration("off-failed"))
        check(!coordinated.isActive && log("off-failed").isEmpty, "关闭视频失败时不启动Scene")
        await backend.setFailOff(false)
        await model.playPreparedScene(configuration("switch"))
        try await wait { coordinated.phase == .playing }
        check(await backend.actions.last == "off", "先关闭视频和轮播再启动Scene")
        await backend.setOldRendererCheck { !hasLivePID("switch") }
        await model.perform(.play("fixture.mp4"))
        check(await backend.oldRendererWasStopped && !coordinated.isActive, "Scene进程退出后才调用视频播放")

        await model.playPreparedScene(configuration("refresh-stop"))
        try await wait { coordinated.phase == .playing }
        model.loading = true
        await model.perform(.off)
        check(!coordinated.isActive && !hasLivePID("refresh-stop"), "读取资料库期间仍可停止场景")
        model.loading = false

        await backend.setOffDelay(true)
        let pending = Task { await model.playPreparedScene(configuration("shutdown")) }
        try await wait { model.busy }
        await model.shutdownScene()
        await pending.value
        check(log("shutdown").isEmpty && !coordinated.isActive, "退出期间禁止迟到的Scene启动")

        try player.start(configuration("stubborn", mode: "stubborn"))
        try await wait { player.phase == .playing }
        let stopStart = ContinuousClock.now
        await player.stop()
        check(!hasLivePID("stubborn") && ContinuousClock.now - stopStart < .seconds(8), "不响应退出的自有子进程被有界回收")

        // Exercise the production argument validation without running a renderer.
        let runtimeRoot = root.appendingPathComponent("runtime")
        let resources = runtimeRoot.appendingPathComponent("Contents/Resources")
        let renderer = resources.appendingPathComponent("Renderers/SceneWallpaper")
        try FileManager.default.createDirectory(at: renderer.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: renderer)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: renderer.path)
        for path in ["Contents/Resources/assets", "Contents/Resources/Renderers/vulkan/icd.d", "Contents/Frameworks"] {
            try FileManager.default.createDirectory(at: runtimeRoot.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try Data().write(to: resources.appendingPathComponent("Renderers/vulkan/icd.d/MoltenVK_icd.json"))
        try Data().write(to: runtimeRoot.appendingPathComponent("Contents/Frameworks/libvulkan.1.dylib"))
        let sceneFolder = root.appendingPathComponent("1000000001")
        try FileManager.default.createDirectory(at: sceneFolder, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: sceneFolder.appendingPathComponent("scene.pkg"))
        let prepared = try SceneLaunchConfiguration.prepare(runtimeURL: runtimeRoot, root: root, name: "1000000001",
            title: "clock", expectedBytes: 3, displayID: 1, fps: 60, cropMode: "auto")
        check(!prepared.arguments.contains("--run-seconds") && prepared.arguments.contains("--follow-focus"), "第一版持续播放不继承60秒试验限制")
        let fpsIndex = prepared.arguments.firstIndex(of: "--fps")!
        let cropIndex = prepared.arguments.firstIndex(of: "--position-x")!
        check(prepared.arguments[fpsIndex + 1] == "60" && prepared.arguments[cropIndex + 1] == "1.0", "帧率和1000000001完整时钟裁切参数生效")
        print("\(count) Scene integration checks passed")
    }

    @MainActor static func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            precondition(ContinuousClock.now < deadline, "condition timed out")
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}

@MainActor private final class FocusFixture { var displayID: UInt32 = 1 }

private actor SceneTestBackend: WallpaperBackend {
    nonisolated let capabilities = BackendCapabilities(name: "test", libraryDirectory: nil)
    var actions: [String] = []
    var failOff = false
    var delayOff = false
    var value = PlaybackState()
    var oldRendererWasStopped = false
    var oldRendererCheck: (@MainActor () -> Bool)?
    func setFailOff(_ value: Bool) { failOff = value }
    func setOffDelay(_ value: Bool) { delayOff = value }
    func setOldRendererCheck(_ check: @escaping @MainActor () -> Bool) { oldRendererCheck = check }
    func library() async throws -> [Wallpaper] { [] }
    func state() async throws -> PlaybackState { value }
    func perform(_ action: Action) async throws {
        switch action {
        case .off:
            actions.append("off")
            if failOff { throw BackendError.message("fixture off failed") }
            if delayOff { try await Task.sleep(for: .milliseconds(300)) }
            value = PlaybackState()
        case .play(let path):
            oldRendererWasStopped = await oldRendererCheck?() ?? false
            actions.append("play")
            value.running = true; value.lastPath = path
        default: break
        }
    }
    func importFiles(_ urls: [URL]) async -> [String] { [] }
    func trash(_ url: URL) async throws { }
    func diagnostics() async throws -> BackendDiagnostics { .init(displays: "", status: "") }
}
