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
        await model.playScene(root: root, name: "../outside", title: "bad", expectedBytes: 1)
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
            title: "clock", expectedBytes: 3, displayID: 1, preferences: ScenePreferences(fps: 60))
        check(!prepared.arguments.contains("--run-seconds") && prepared.arguments.contains("--follow-focus"), "第一版持续播放不继承60秒试验限制")
        let fpsIndex = prepared.arguments.firstIndex(of: "--fps")!
        let cropIndex = prepared.arguments.firstIndex(of: "--position-x")!
        check(prepared.arguments[fpsIndex + 1] == "60" && prepared.arguments[cropIndex + 1] == "1.0", "帧率和1000000001完整时钟裁切参数生效")

        // Preference persistence, normalization and immutable launch snapshots.
        let suiteName = "ScenePreferencesChecks-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        check(ScenePreferences.load(from: defaults) == ScenePreferences(), "新设置保持原有播放默认值")
        defaults.set(17, forKey: ScenePreferences.Key.fps)
        defaults.set(0, forKey: ScenePreferences.Key.inputHz)
        defaults.set("unknown", forKey: ScenePreferences.Key.crop)
        check(ScenePreferences.load(from: defaults) == ScenePreferences(), "无效偏好回退到有效帧率采样与裁切")
        defaults.set(false, forKey: ScenePreferences.Key.mouse)
        defaults.set(false, forKey: ScenePreferences.Key.buttons)
        defaults.set(120, forKey: ScenePreferences.Key.inputHz)
        defaults.set(false, forKey: ScenePreferences.Key.followsDisplay)
        defaults.set(true, forKey: ScenePreferences.Key.sound)
        defaults.set(true, forKey: ScenePreferences.Key.audioResponse)
        let requested = ScenePreferences.load(from: defaults)
        let configured = try SceneLaunchConfiguration.prepare(runtimeURL: runtimeRoot, root: root, name: "1000000001",
            title: "clock", expectedBytes: 3, displayID: 1, preferences: requested)
        check(configured.arguments.contains("--no-mouse") && configured.arguments.contains("--no-mouse-buttons"), "关闭鼠标与点击转换为真实渲染器参数")
        check(configured.arguments[configured.arguments.firstIndex(of: "--input-hz")! + 1] == "120", "保存的采样频率传入渲染器")
        check(!configured.arguments.contains("--muted") && !configured.arguments.contains("--no-spectrum"), "声音与音频响应分别控制渲染器参数")
        check(!configured.preferences.followsDisplay && configured.arguments.contains("--follow-focus"), "关闭跨屏跟随后仍保留跨Space窗口能力")
        defaults.set(true, forKey: ScenePreferences.Key.mouse)
        check(!configured.preferences.mouseEnabled && ScenePreferences.load(from: defaults).mouseEnabled, "修改保存值不改变运行会话快照")
        var invalid = ScenePreferences()
        invalid.inputHz = 0
        do {
            _ = try SceneLaunchConfiguration.prepare(runtimeURL: runtimeRoot, root: root, name: "1000000001",
                title: "clock", expectedBytes: 3, displayID: 1, preferences: invalid)
            preconditionFailure("invalid sampling accepted")
        } catch { check(true, "无效采样频率在停止旧场景前被拒绝") }

        let fixedFocus = FocusFixture()
        let fixed = ScenePlayer(focusProvider: { fixedFocus.displayID })
        var fixedConfig = configuration("fixed")
        fixedConfig.preferences.followsDisplay = false
        try fixed.start(fixedConfig)
        try await wait { fixed.phase == .playing }
        fixedFocus.displayID = 3
        try await Task.sleep(for: .milliseconds(1800))
        check(fixed.displayID == 1 && !log("fixed").contains("moveDisplay"), "关闭跟随后焦点变化不会移动场景")
        await fixed.stop()
        check(fixed.activePreferences == nil, "停止后清理已应用设置快照")

        // Exercise UI's reapply path through input validation and the real coordinator.
        let settingsLog = renderer.deletingLastPathComponent().appendingPathComponent("settings.log")
        try #"""
        #!/bin/sh
        log="$(dirname "$0")/settings.log"
        printf 'start\n' >> "$log"
        printf '%s\n' "$@" >> "$log"
        printf '%s\n' '{"event":"scene-ready"}' '{"event":"first-frame-presented"}'
        while IFS= read -r command; do
          case "$command" in
            '{"cmd":"activate"}') printf '%s\n' '{"event":"activated"}' ;;
            '{"cmd":"deactivate"}') printf '%s\n' '{"event":"deactivated"}' ;;
            '{"cmd":"quit"}') exit 0 ;;
          esac
        done
        """#.write(to: renderer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: renderer.path)
        // Per-package storage, migration, corruption isolation and reload.
        let perItemSuite = "PerSceneChecks-" + UUID().uuidString
        let perItemDefaults = UserDefaults(suiteName: perItemSuite)!
        defer { perItemDefaults.removePersistentDomain(forName: perItemSuite) }
        perItemDefaults.set("left", forKey: ScenePreferences.Key.crop)
        let store = ScenePreferencesStore(defaults: perItemDefaults)
        let packageA = sceneFolder.appendingPathComponent("scene.pkg")
        let folderB = root.appendingPathComponent("second-scene")
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        let packageB = folderB.appendingPathComponent("scene.pkg")
        try Data([4, 5, 6]).write(to: packageB)
        let otherLibraryPackage = root.appendingPathComponent("other-library/1000000001/scene.pkg")
        let initial = ScenePreferences(cropMode: "left")
        check(store.preferences(for: packageA) == initial && store.preferences(for: packageB) == initial,
              "旧全局设置保留为迁移初始值")
        var settingsA = requested
        settingsA.cropMode = "right"
        let settingsB = ScenePreferences(fps: 60, inputHz: 30)
        store.save(settingsA, for: packageA)
        check(store.preferences(for: packageA) == settingsA && store.preferences(for: packageB) == initial,
              "修改A不改变尚未编辑的B")
        store.save(settingsB, for: packageB)
        check(store.preferences(for: packageA) == settingsA && store.preferences(for: packageB) == settingsB,
              "A与B的交互播放声音设置分别保存")
        let reloaded = ScenePreferencesStore(defaults: UserDefaults(suiteName: perItemSuite)!)
        check(reloaded.preferences(for: packageA) == settingsA && reloaded.preferences(for: packageB) == settingsB,
              "重新创建存储后仍读取各自设置")
        perItemDefaults.set(false, forKey: ScenePreferences.Key.mouse)
        perItemDefaults.set("right", forKey: ScenePreferences.Key.crop)
        let migratedAgain = ScenePreferencesStore(defaults: perItemDefaults)
        check(migratedAgain.preferences(for: otherLibraryPackage) == initial,
              "全局旧值后续变化不会再次迁移或串改壁纸")
        check(store.preferences(for: otherLibraryPackage) != settingsA,
              "不同资料库的相同目录名不共用设置")
        let aliasA = root.appendingPathComponent("second-scene/../1000000001/scene.pkg")
        check(store.preferences(for: aliasA) == settingsA, "等价规范路径使用同一壁纸设置")
        perItemDefaults.set(Data("broken".utf8), forKey: ScenePreferencesStore.storageKey(for: packageA))
        check(store.preferences(for: packageA) == initial && store.preferences(for: packageB) == settingsB,
              "单条设置损坏不会影响其他壁纸")
        store.save(ScenePreferences(fps: 17, cropMode: "bad", inputHz: 0), for: otherLibraryPackage)
        check(store.preferences(for: otherLibraryPackage) == ScenePreferences(), "独立设置校验非法采样帧率与裁切")
        store.save(.init(), for: packageA)
        let settingsBackend = SceneTestBackend()
        let settingsPlayer = ScenePlayer(focusProvider: { 1 })
        let settingsModel = LibraryModel(backend: settingsBackend, scenePlayer: settingsPlayer, sceneRuntimeURL: runtimeRoot, scenePreferences: store)
        await settingsModel.applyScenePreferences(for: packageA)
        check(await settingsBackend.actions.isEmpty, "未播放时应用设置不会启动壁纸")
        await settingsModel.playScene(root: root, name: "1000000001", title: "clock", expectedBytes: 3)
        try await wait { settingsPlayer.phase == .playing }
        check(settingsPlayer.activePreferences == ScenePreferences(), "播放入口读取选中壁纸自己的配置")
        store.save(requested, for: packageB)
        await settingsModel.applyScenePreferences(for: packageB)
        check(await settingsBackend.actions.count == 1 && settingsPlayer.activePreferences == ScenePreferences(),
              "编辑和应用B不会更改或重启正在播放的A")
        store.save(requested, for: packageA)
        check(settingsPlayer.activePreferences == ScenePreferences(), "编辑A后运行快照保持原值直到应用")
        await settingsBackend.setOffDelay(true)
        let applying = Task { await settingsModel.applyScenePreferences(for: packageA) }
        try await wait { settingsModel.busy }
        await settingsModel.applyScenePreferences(for: packageA)
        await applying.value
        try await wait { settingsPlayer.phase == .playing }
        let launches = try String(contentsOf: settingsLog, encoding: .utf8).components(separatedBy: "\n").filter { $0 == "start" }.count
        check(launches == 2 && settingsPlayer.activePreferences == requested, "应用设置只重播一次且拒绝重复点击")
        check(await settingsBackend.actions.count == 2, "应用设置沿用引擎互斥协调器")
        await settingsModel.stopScene()
        store.save(settingsB, for: packageB)
        await settingsModel.playScene(root: root, name: "second-scene", title: "clock", expectedBytes: 3)
        try await wait { settingsPlayer.phase == .playing }
        check(settingsPlayer.activePreferences == settingsB && store.preferences(for: packageA) == requested,
              "切换到同名B时加载B设置并保留A")
        await settingsModel.stopScene()
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
