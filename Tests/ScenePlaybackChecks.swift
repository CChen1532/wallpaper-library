import Foundation
import Darwin
import AppKit
import ImageIO
import UniformTypeIdentifiers

@main struct ScenePlaybackChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ name: String) {
            precondition(value, "FAIL: " + name)
            count += 1
            print("PASS: " + name)
        }
        check(GravityScene.Preset.ultra.fps == 120 && GravityScene.Preset.efficient.fps == 30,
              "极致版目标120FPS，性能版保持30FPS")
        let ultraSize = GravityScene.Preset.ultra.renderSize(width: 1920, height: 1080)
        check(ultraSize.width == 3840 && ultraSize.height == 2160, "低于4K的显示器仍以真实4K离屏渲染")
        let tallSize = GravityScene.Preset.ultra.renderSize(width: 1440, height: 2560)
        check(tallSize.width == 2160 && tallSize.height == 3840, "4K竖屏保持比例并限制纹理长边")
        let nativeAspect = GravityScene.Preset.ultra.renderSize(width: 2400, height: 1600)
        check(nativeAspect.width == 3840 && nativeAspect.height == 2560, "4K保留非16比9屏幕的完整画面")
        let efficientSize = GravityScene.Preset.efficient.renderSize(width: 2400, height: 1600)
        check(efficientSize.width == 1600, "性能版保留1600宽上限")
        let nativeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("gravity-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: nativeRoot.appendingPathComponent("native"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: nativeRoot) }
        let manifest = nativeRoot.appendingPathComponent("native/scene.pkg")
        let manifestData = Data(#"{"format":"wallpaperui.gravity.v1","preset":"efficient"}"#.utf8)
        try manifestData.write(to: manifest)
        check((try GravityScene.load(manifest))?.preset == .efficient, "原生引力包仅接受声明式预设")
        let nativeRenderer = nativeRoot.appendingPathComponent("GravitySceneRenderer")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: nativeRenderer)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: nativeRenderer.path)
        let nativeLaunch = try SceneLaunchConfiguration.prepare(runtimeURL: nativeRoot.appendingPathComponent("SceneRuntime"),
            root: nativeRoot, name: "native", title: "Gravity", expectedBytes: Int64(manifestData.count), displayID: 1)
        check(nativeLaunch.executable == nativeRenderer && nativeLaunch.arguments.contains("efficient") &&
              nativeLaunch.arguments.contains("--deferred-show") && !nativeLaunch.preferences.mouseEnabled,
              "原生引力场景选择专用渲染器并禁用交互、等待底图后显示")
        try Data(#"{"format":"wallpaperui.gravity.v1","preset":"arbitrary-code"}"#.utf8).write(to: manifest)
        do { _ = try GravityScene.load(manifest); preconditionFailure("invalid preset accepted") }
        catch { check(true, "原生包拒绝未知预设") }
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: nativeRenderer)
        check((try GravityScene.load(manifest)) == nil, "原生包拒绝符号链接")
        var stability = SystemWallpaperStabilityGate()
        check(!stability.observe(matches: true, at: 0) &&
              !stability.observe(matches: true, at: 0.2) &&
              !stability.observe(matches: true, at: 0.4) &&
              !stability.observe(matches: false, at: 0.8),
              "全空间底图短暂匹配后回退时不启动场景")
        var acceptedBeforeStable = false
        for sample in 0...14 {
            acceptedBeforeStable = stability.observe(matches: true, at: 1.6 + Double(sample) * 0.2) || acceptedBeforeStable
        }
        check(!acceptedBeforeStable && stability.observe(matches: true, at: 4.8),
              "回退后重新连续稳定3秒才允许激活场景")
        var stalled = SystemWallpaperStabilityGate()
        check(!stalled.observe(matches: true, at: 0) &&
              !stalled.observe(matches: true, at: 1.0) &&
              !stalled.observe(matches: true, at: 3.0),
              "采样间隔过长不能冒充持续稳定")
        var activation = SystemWallpaperActivationGate()
        check(activation.observe(matches: false, switchIsOn: false, at: 0) == .press,
              "全空间开关关闭时首次按下")
        for sample in 1...4 {
            check(activation.observe(matches: true, switchIsOn: true, at: Double(sample) * 0.2) == .wait,
                  "短暂开启不足稳定时间")
        }
        check(activation.observe(matches: false, switchIsOn: false, at: 1) == .wait &&
              activation.observe(matches: false, switchIsOn: false, at: 2) == .press,
              "系统撤销第一次按下后只在开关重新关闭时重试")
        var completed = false
        for sample in 1...17 {
            completed = activation.observe(matches: true, switchIsOn: true,
                                            at: 2 + Double(sample) * 0.2) == .complete || completed
        }
        check(completed && activation.pressCount == 2, "第二次开启连续稳定后完成")
        var bounded = SystemWallpaperActivationGate()
        check(bounded.observe(matches: false, switchIsOn: false, at: 0) == .press &&
              bounded.observe(matches: false, switchIsOn: false, at: 2) == .press &&
              bounded.observe(matches: false, switchIsOn: false, at: 4) == .press &&
              bounded.observe(matches: false, switchIsOn: false, at: 6) == .wait,
              "最多尝试三次，避免无限切换系统开关")
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

        let screen1 = SceneDisplay(id: 1, uuid: "00000000-0000-0000-0000-000000000001", name: "Screen A")
        let screen3 = SceneDisplay(id: 3, uuid: "00000000-0000-0000-0000-000000000003", name: "Screen B")
        let player = ScenePlayer(focusProvider: { 1 }, displayProvider: { [screen1] })
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
        let following = ScenePlayer(focusProvider: { focus.displayID }, displayProvider: { [screen1, screen3] })
        try following.start(configuration("follow"))
        try await wait { following.phase == .playing }
        focus.displayID = 3
        try await Task.sleep(for: .milliseconds(700))
        check(following.displayID == 1, "新焦点不足1.5秒时旧屏继续播放")
        try await wait { following.displayID == 3 }
        check(!following.automaticBackdropActive && following.automaticBackdropImage == nil,
              "关闭底图的场景跨屏后不会误报已匹配")
        focus.displayID = 1
        await following.stop()
        check(!hasLivePID("follow") && !log("follow").contains("displayID\":1"), "停止取消尚未完成的焦点交接")

        try player.start(configuration("crash", mode: "crash"))
        try await wait { player.phase == .failed }
        check(player.error != nil && !player.isActive && !hasLivePID("crash"), "异常退出显示错误并清理状态")

        let coordinated = ScenePlayer(focusProvider: { 1 }, displayProvider: { [screen1] })
        let backdropDefaultsName = "WallpaperUI.BackdropDefaults." + UUID().uuidString
        let backdropDefaults = UserDefaults(suiteName: backdropDefaultsName)!
        defer { backdropDefaults.removePersistentDomain(forName: backdropDefaultsName) }
        check(!SceneBackdropConfiguration.isEnabled(in: backdropDefaults), "未配置的场景默认不修改系统过渡底图")
        backdropDefaults.set(true, forKey: SceneBackdropConfiguration.preferenceKey)
        check(SceneBackdropConfiguration.isEnabled(in: backdropDefaults), "用户明确开启的场景底图设置保留")
        let incompatibleHelper = root.appendingPathComponent("incompatible-helper.py")
        try "import sys; print('unverified wallpaper schema', file=sys.stderr); sys.exit(3)\n"
            .write(to: incompatibleHelper, atomically: true, encoding: .utf8)
        let incompatibleSettings = SceneBackdropConfiguration(helper: incompatibleHelper, inventory: root,
            state: root.appendingPathComponent("compatibility-fixture"))
        do {
            try await SpaceBackdropCompatibility.check(incompatibleSettings, displayID: 1)
            preconditionFailure("不兼容系统墙纸格式被接受")
        } catch is SpaceBackdropCompatibilityFailure {
            check(true, "不兼容墙纸格式作为可自动停用的独立错误返回")
        }
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
        let largeFolder = root.appendingPathComponent("large-scene")
        try FileManager.default.createDirectory(at: largeFolder, withIntermediateDirectories: true)
        let largePackage = largeFolder.appendingPathComponent("scene.pkg")
        try Data([1]).write(to: largePackage)
        let largeBytes: UInt64 = 257 * 1024 * 1024
        let largeHandle = try FileHandle(forWritingTo: largePackage)
        try largeHandle.truncate(atOffset: largeBytes) // Sparse: exercise launch validation without allocating the package.
        try largeHandle.close()
        let largePrepared = try SceneLaunchConfiguration.prepare(runtimeURL: runtimeRoot, root: root,
            name: "large-scene", title: "large", expectedBytes: Int64(largeBytes), displayID: 1)
        check(largePrepared.arguments.last == largePackage.path &&
              !largePrepared.arguments.contains("--run-seconds"),
              "超过256MiB的普通场景包可生成正式播放参数")
        let linkedFolder = root.appendingPathComponent("linked-scene")
        try FileManager.default.createDirectory(at: linkedFolder, withIntermediateDirectories: true)
        let linkedPackage = linkedFolder.appendingPathComponent("scene.pkg")
        try FileManager.default.createSymbolicLink(at: linkedPackage, withDestinationURL: largePackage)
        let bridge = try MirageSceneRuntime(app: runtimeRoot)
        do {
            _ = try bridge.playbackArguments(scenePackage: linkedPackage, displayID: 1)
            preconditionFailure("场景包链接绕过启动校验")
        } catch is MirageSceneBridgeError {
            check(true, "取消整包大小上限后仍拒绝链接场景包")
        }
        let fpsIndex = prepared.arguments.firstIndex(of: "--fps")!
        let cropIndex = prepared.arguments.firstIndex(of: "--position-x")!
        check(prepared.arguments[fpsIndex + 1] == "60" && prepared.arguments[cropIndex + 1] == "1.0", "帧率和1000000001完整时钟裁切参数生效")
        check(!prepared.arguments.contains("--user-properties"), "没有水印属性的场景不接受额外覆盖")
        let preparation = ScenePreparationCache()
        let warmed = try await preparation.prepare(runtimeURL: runtimeRoot, root: root, name: "1000000001",
                                                    title: "clock", expectedBytes: 3, displayID: 1,
                                                    preferences: ScenePreferences(fps: 60))
        let reused = try await preparation.prepare(runtimeURL: runtimeRoot, root: root, name: "1000000001",
                                                    title: "clock", expectedBytes: 3, displayID: 1,
                                                    preferences: ScenePreferences(fps: 60))
        check(warmed.arguments == reused.arguments, "选中场景预热的启动参数可复用")
        let changedPreparation = try await preparation.prepare(runtimeURL: runtimeRoot, root: root, name: "1000000001",
                                                     title: "clock", expectedBytes: 3, displayID: 1,
                                                     preferences: ScenePreferences(fps: 30))
        check(changedPreparation.arguments != warmed.arguments, "场景设置变化不复用旧启动参数")
        let warmFolder = root.appendingPathComponent("warm-scene")
        try FileManager.default.createDirectory(at: warmFolder, withIntermediateDirectories: true)
        let warmPackage = warmFolder.appendingPathComponent("scene.pkg")
        try Data([1, 2, 3]).write(to: warmPackage)
        _ = try await preparation.prepare(runtimeURL: runtimeRoot, root: root, name: "warm-scene",
                                          title: "warm", expectedBytes: 3, displayID: 1,
                                          preferences: .init())
        try Data([1, 2, 3, 4]).write(to: warmPackage)
        do {
            _ = try await preparation.prepare(runtimeURL: runtimeRoot, root: root, name: "warm-scene",
                                              title: "warm", expectedBytes: 3, displayID: 1,
                                              preferences: .init())
            preconditionFailure("缓存绕过已变化的场景包")
        } catch { check(true, "预热缓存仍校验场景包变化") }

        let markedFolder = root.appendingPathComponent("marked-scene")
        try FileManager.default.createDirectory(at: markedFolder, withIntermediateDirectories: true)
        let markedPackage = markedFolder.appendingPathComponent("scene.pkg")
        try Data([4, 5, 6]).write(to: markedPackage)
        let projectFile = markedFolder.appendingPathComponent("project.json")
        let originalProject = Data(#"""
        {"general":{"properties":{
          "watermark":{"type":"bool","text":"作者水印","value":true},
          "fog":{"type":"bool","text":"雾效","value":false},
          "parallax":{"type":"slider","text":"视差","min":0,"max":2,"step":0.1,"value":1},
          "season":{"type":"combo","text":"季节","value":"0","options":[{"label":"春","value":"0"},{"label":"冬","value":"1"}]},
          "schemecolor":{"type":"color","text":"颜色","value":"1 0.5 0"},
          "caption":{"type":"textinput","text":"文字","value":"hello"},
          "promo":{"type":"bool","text":"<a href='https://example.com'>link</a>","value":true},
          "heading":{"type":"group","text":"组","value":0}
        }}}
        """#.utf8)
        try originalProject.write(to: projectFile)
        let propertyDefaults = UserDefaults(suiteName: "ScenePropertyChecks-" + UUID().uuidString)!
        let propertyStore = SceneUserPropertiesStore(defaults: propertyDefaults,
            directory: root.appendingPathComponent("saved-properties"))
        let catalog = propertyStore.catalog(for: markedPackage)
        check(catalog.properties.count == 6 && catalog.properties.first?.label == "作者水印" &&
              !catalog.properties.contains(where: { $0.id == "promo" || $0.id == "heading" }),
              "只展示可编辑属性，过滤链接和非控件元数据")
        let watermark = catalog.properties.first { $0.id == "watermark" }!
        let fog = catalog.properties.first { $0.id == "fog" }!
        let parallax = catalog.properties.first { $0.id == "parallax" }!
        let color = catalog.properties.first { $0.id == "schemecolor" }!
        check(propertyStore.value(for: watermark, package: markedPackage) == .boolean(false),
              "作者默认开启的水印在本应用中默认关闭")
        check(propertyStore.value(for: fog, package: markedPackage) == .boolean(false),
              "其他场景效果保留作者默认值")
        check(parallax.validated(NSNumber(value: 2.5)) == nil &&
              color.validated("99 0 0") == nil &&
              watermark.validated(NSNumber(value: 1)) == nil,
              "越界效果值和错误类型不能交给渲染器")
        let launch = try propertyStore.launch(for: markedPackage)
        let backgroundLaunch = try await propertyStore.launchInBackground(for: markedPackage)
        check(backgroundLaunch.effectiveValues == launch.effectiveValues &&
              backgroundLaunch.file == launch.file,
              "后台准备属性覆盖与原有首帧配置一致")
        var marked = try SceneLaunchConfiguration.prepare(runtimeURL: runtimeRoot, root: root, name: "marked-scene",
            title: "marked", expectedBytes: 3, displayID: 1)
        marked.setUserProperties(launch)
        let propertyIndex = marked.arguments.firstIndex(of: "--user-properties")!
        let overrideJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: launch.file!)) as! [String: Bool]
        check(overrideJSON == ["watermark": false] && marked.arguments[propertyIndex + 1] == launch.file!.path &&
              propertyIndex < marked.arguments.count - 2 &&
              marked.arguments.last == marked.package.path,
              "首帧前传入当前场景独立覆盖文件且仅关闭水印")
        check(try Data(contentsOf: projectFile) == originalProject, "启动配置不修改原始作者署名和场景配置")
        propertyStore.save(.boolean(true), for: fog, package: markedPackage)
        propertyStore.save(.number(1.5), for: parallax, package: markedPackage)
        propertyStore.save(.string("0.2 0.3 0.4"), for: color, package: markedPackage)
        let changed = try propertyStore.launch(for: markedPackage)
        let changedJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: changed.file!)) as! [String: Any]
        check(changedJSON["fog"] as? Bool == true && changedJSON["parallax"] as? Double == 1.5 &&
              changedJSON["schemecolor"] as? String == "0.2 0.3 0.4" && changedJSON["watermark"] as? Bool == false,
              "布尔、滑块和颜色效果以校验后的值传给渲染器")
        let reloadedProperties = SceneUserPropertiesStore(defaults: propertyDefaults,
            directory: root.appendingPathComponent("saved-properties"))
        check(reloadedProperties.value(for: fog, package: markedPackage) == .boolean(true) &&
              reloadedProperties.value(for: watermark, package: markedPackage) == .boolean(false),
              "重新创建存储后仍读取场景自己的效果")
        let otherPackage = root.appendingPathComponent("other-marked/scene.pkg")
        try FileManager.default.createDirectory(at: otherPackage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([7, 8, 9]).write(to: otherPackage)
        try originalProject.write(to: otherPackage.deletingLastPathComponent().appendingPathComponent("project.json"))
        let otherCatalog = propertyStore.catalog(for: otherPackage)
        let otherFog = otherCatalog.properties.first { $0.id == "fog" }!
        let otherLaunch = try propertyStore.launch(for: otherPackage)
        check(propertyStore.value(for: otherFog, package: otherPackage) == .boolean(false) &&
              otherLaunch.file != changed.file,
              "同内容不同壁纸使用各自独立设置与覆盖文件")
        propertyStore.save(.boolean(true), for: watermark, package: markedPackage)
        let visibleWatermark = try propertyStore.launch(for: markedPackage)
        let visibleJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: visibleWatermark.file!)) as! [String: Any]
        check(visibleJSON["watermark"] == nil && visibleJSON["fog"] as? Bool == true,
              "用户开启水印后恢复作者默认画面，其他效果不受影响")

        let legacySliderFolder = root.appendingPathComponent("legacy-sliders")
        try FileManager.default.createDirectory(at: legacySliderFolder, withIntermediateDirectories: true)
        let legacySliderPackage = legacySliderFolder.appendingPathComponent("scene.pkg")
        try Data(#"""
        {"general":{"properties":{
          "music":{"type":"slider","text":"音乐","min":1,"max":4,"fraction":false,"value":1},
          "x":{"type":"slider","text":"时间横坐标","min":100,"max":2438,"fraction":false,"value":1269},
          "implicit":{"type":"slider","text":"整数","min":0,"max":10,"value":3},
          "zeroStep":{"type":"slider","text":"坏步长","min":0,"max":10,"step":0,"value":3},
          "boolStep":{"type":"slider","text":"坏类型","min":0,"max":10,"step":true,"value":3},
          "fraction":{"type":"slider","text":"未知小数精度","min":0,"max":1,"fraction":true,"value":0.5},
          "badFraction":{"type":"slider","text":"坏类型","min":0,"max":10,"fraction":0,"value":3},
          "fractionalRange":{"type":"slider","text":"非整数范围","min":0.5,"max":10,"value":3},
          "hugeRange":{"type":"slider","text":"超长范围","min":0,"max":100001,"value":3}
        }}}
        """#.utf8).write(to: legacySliderFolder.appendingPathComponent("project.json"))
        let legacySliders = ScenePropertyCatalog.load(for: legacySliderPackage)
        check(Set(legacySliders.properties.map(\.id)) == Set(["music", "x", "implicit"]),
              "缺少step的整数滑块仍显示，非法步长和不明确的小数精度仍拒绝")
        let legacyX = legacySliders.properties.first { $0.id == "x" }!
        check(legacyX.sourceDefault == .number(1269) &&
              legacyX.validated(NSNumber(value: 1270.4)) == .number(1270),
              "旧格式坐标滑块保持作者默认值并按整数步进")
        propertyStore.save(.number(1300), for: legacyX, package: legacySliderPackage)
        let legacyLaunch = try propertyStore.launch(for: legacySliderPackage)
        let legacyJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyLaunch.file!)) as! [String: Any]
        check((legacyJSON["x"] as? NSNumber)?.intValue == 1300,
              "旧格式滑块修改值可实际写入渲染器覆盖文件")

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
        let fixed = ScenePlayer(focusProvider: { fixedFocus.displayID }, displayProvider: { [screen1, screen3] })
        var fixedConfig = configuration("fixed")
        fixedConfig.preferences.followsDisplay = false
        try fixed.start(fixedConfig)
        try await wait { fixed.phase == .playing }
        fixedFocus.displayID = 3
        try await Task.sleep(for: .milliseconds(1800))
        check(fixed.displayID == 1 && !log("fixed").contains("moveDisplay"), "关闭跟随后焦点变化不会移动场景")
        await fixed.stop()
        check(fixed.activePreferences == nil, "停止后清理已应用设置快照")

        var selectedScreen = ScenePreferences()
        selectedScreen.followsDisplay = false
        selectedScreen.displayUUID = screen1.uuid
        selectedScreen.displayName = screen1.name
        let remapped = SceneDisplay(id: 99, uuid: screen1.uuid, name: screen1.name)
        check(SceneDisplay.resolve(selectedScreen, displays: [screen3, remapped], focus: 3) == 99,
              "固定屏幕按UUID查找，不依赖重连后变化的数字ID")
        check(SceneDisplay.resolve(.init(), displays: [screen1, screen3], focus: 3) == 3,
              "自动跟随可选择非主屏")
        check(SceneDisplay.resolve(selectedScreen, displays: [], focus: 1) == nil,
              "无连接显示器时不会返回失效屏幕")
        let topology = DisplayFixture([screen1])
        let reconnecting = ScenePlayer(focusProvider: { 3 }, displayProvider: { topology.screens })
        check(reconnecting.preferredDisplayID(preferences: selectedScreen) == 1,
              "启动时优先使用壁纸保存的固定屏幕")
        var reconnectConfig = configuration("reconnect")
        reconnectConfig.preferences = selectedScreen
        try reconnecting.start(reconnectConfig)
        try await wait { reconnecting.phase == .playing }
        topology.screens = [screen3]
        try await wait { reconnecting.displayID == 3 }
        check(reconnecting.activePreferences?.displayUUID == screen1.uuid,
              "固定屏幕断开后回退到可用屏幕且不改写保存选择")
        topology.screens = [screen3, screen1]
        try await wait { reconnecting.displayID == 1 }
        await reconnecting.stop()
        check(!hasLivePID("reconnect"), "固定屏幕重连后自动返回，停止清理唯一渲染进程")

        let multiPlayer = ScenePlayer(focusProvider: { 1 }, displayProvider: { [screen1, screen3] })
        let multiModel = LibraryModel(backend: SceneTestBackend(), scenePlayer: multiPlayer)
        var multiConfig = configuration("multi")
        multiConfig.backdrop = incompatibleSettings
        await multiModel.playPreparedScene(multiConfig)
        try await wait { multiPlayer.phase == .playing }
        check(!multiPlayer.automaticBackdropActive && multiModel.backdropCompatibilityIssue != nil,
              "多屏下跳过全局底图组件，场景正常启动并明确提示")
        await multiPlayer.stop()

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
        settingsA.displayUUID = screen1.uuid
        settingsA.displayName = screen1.name
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
        var oldFields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settingsA)) as! [String: Any]
        oldFields.removeValue(forKey: "displayUUID")
        oldFields.removeValue(forKey: "displayName")
        let legacyPreferences = try JSONDecoder().decode(ScenePreferences.self, from: JSONSerialization.data(withJSONObject: oldFields))
        check(legacyPreferences.displayUUID == nil && legacyPreferences.cropMode == "right" &&
              legacyPreferences.mouseEnabled == settingsA.mouseEnabled,
              "旧版逐壁纸配置缺少显示器字段时仍保留原设置")
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
        let playbackProject = Data(#"{"general":{"properties":{"watermark":{"type":"bool","text":"水印","value":true}}}}"#.utf8)
        try playbackProject.write(to: sceneFolder.appendingPathComponent("project.json"))
        try playbackProject.write(to: folderB.appendingPathComponent("project.json"))
        let playbackProperties = SceneUserPropertiesStore(defaults: perItemDefaults,
            directory: root.appendingPathComponent("playback-properties"))
        let playbackWatermark = playbackProperties.catalog(for: packageA).properties.first!
        let settingsBackend = SceneTestBackend()
        let settingsPlayer = ScenePlayer(focusProvider: { 1 }, displayProvider: { [screen1] })
        let settingsModel = LibraryModel(backend: settingsBackend, scenePlayer: settingsPlayer,
            sceneRuntimeURL: runtimeRoot, scenePreferences: store, sceneUserProperties: playbackProperties,
            backdropConfiguration: { nil })
        await settingsModel.applyScenePreferences(for: packageA)
        check(await settingsBackend.actions.isEmpty, "未播放时应用设置不会启动壁纸")
        await settingsModel.playScene(root: root, name: "1000000001", title: "clock", expectedBytes: 3)
        try await wait { settingsPlayer.phase == .playing }
        check(settingsPlayer.activePreferences == ScenePreferences(), "播放入口读取选中壁纸自己的配置")
        let firstSceneLog = try String(contentsOf: settingsLog, encoding: .utf8)
        check(settingsPlayer.activeUserPropertyValues["watermark"] == .boolean(false) &&
              firstSceneLog.contains("--user-properties"),
              "播放入口在首帧前装载此场景的水印设置")
        store.save(requested, for: packageB)
        await settingsModel.applyScenePreferences(for: packageB)
        check(await settingsBackend.actions.count == 1 && settingsPlayer.activePreferences == ScenePreferences(),
              "编辑和应用B不会更改或重启正在播放的A")
        store.save(requested, for: packageA)
        playbackProperties.save(.boolean(true), for: playbackWatermark, package: packageA)
        check(settingsPlayer.activePreferences == ScenePreferences(), "编辑A后运行快照保持原值直到应用")
        check(settingsPlayer.activeUserPropertyValues["watermark"] == .boolean(false),
              "编辑中的场景效果不改动当前播放快照")
        await settingsBackend.setOffDelay(true)
        let applying = Task { await settingsModel.applyScenePreferences(for: packageA) }
        try await wait { settingsModel.busy }
        await settingsModel.applyScenePreferences(for: packageA)
        await applying.value
        try await wait { settingsPlayer.phase == .playing }
        let launches = try String(contentsOf: settingsLog, encoding: .utf8).components(separatedBy: "\n").filter { $0 == "start" }.count
        check(launches == 2 && settingsPlayer.activePreferences == requested, "应用设置只重播一次且拒绝重复点击")
        check(settingsPlayer.activeUserPropertyValues["watermark"] == .boolean(true),
              "应用后只更新当前壁纸的场景效果")
        check(await settingsBackend.actions.count == 2, "应用设置沿用引擎互斥协调器")
        await settingsModel.stopScene()
        store.save(settingsB, for: packageB)
        await settingsModel.playScene(root: root, name: "second-scene", title: "clock", expectedBytes: 3)
        try await wait { settingsPlayer.phase == .playing }
        check(settingsPlayer.activePreferences == settingsB && store.preferences(for: packageA) == requested,
              "切换到同名B时加载B设置并保留A")
        check(settingsPlayer.activeUserPropertyValues["watermark"] == .boolean(false) &&
              playbackProperties.value(for: playbackWatermark, package: packageA) == .boolean(true),
              "切换到B后自动读取B的效果且不串改A")
        await settingsModel.stopScene()
        // Automatic backdrop lifecycle uses an isolated fixture, never macOS settings.
        var backdropConfig = SceneBackdropConfiguration(helper: root.appendingPathComponent("fake.py"), inventory: root, state: root.appendingPathComponent("backdrop"))
        let backdrop = BackdropFixture()
        let backdropFocus = FocusFixture()
        let automatic = ScenePlayer(focusProvider: { backdropFocus.displayID },
            displayProvider: { backdropFocus.displayID == 1 ? [screen1] : [screen3] }, backdropFactory: { _ in backdrop })
        var automaticConfig = configuration("automatic")
        automaticConfig.backdrop = backdropConfig
        try automatic.start(automaticConfig)
        try await wait { automatic.phase == .playing }
        check(automatic.automaticBackdropActive && backdrop.events == ["apply:1"], "自动底图在激活场景前完成")
        backdropFocus.displayID = 3
        try await wait { automatic.displayID == 3 }
        check(backdrop.events == ["apply:1", "restore", "apply:3"], "跨屏先复原旧屏再匹配目标屏底图")
        await automatic.stop()
        check(backdrop.events.last == "restore" && !automatic.automaticBackdropActive && !automatic.restorationPending,
              "停止场景自动复原且清理匹配状态")

        let addedTopology = DisplayFixture([screen1])
        let releasedBackdrop = BackdropFixture()
        let addedPlayer = ScenePlayer(focusProvider: { 3 }, displayProvider: { addedTopology.screens },
            backdropFactory: { _ in releasedBackdrop })
        var addedConfig = configuration("added-display")
        addedConfig.backdrop = backdropConfig
        try addedPlayer.start(addedConfig)
        try await wait { addedPlayer.phase == .playing }
        addedTopology.screens = [screen1, screen3]
        try await wait { addedPlayer.displayID == 3 }
        check(releasedBackdrop.events == ["apply:1", "restore"] && !addedPlayer.automaticBackdropActive && addedPlayer.notice != nil,
              "新增显示器先恢复单屏底图，再移动场景而不重设全局壁纸")
        await addedPlayer.stop()
        check(addedPlayer.notice == nil && !hasLivePID("added-display"), "停止多屏场景清理提示与进程")

        let rollback = BackdropFixture()
        let failingRenderer = ScenePlayer(focusProvider: { 1 }, displayProvider: { [screen1] }, backdropFactory: { _ in rollback })
        var crashConfig = configuration("backdrop-crash", mode: "crash")
        crashConfig.backdrop = backdropConfig
        try failingRenderer.start(crashConfig)
        try await wait { failingRenderer.phase == .failed }
        check(rollback.events == ["apply:1", "restore"] && !failingRenderer.restorationPending, "渲染器崩溃仍复原底图")

        let conflict = BackdropFixture(failRestore: true)
        let blockedPlayer = ScenePlayer(focusProvider: { 1 }, displayProvider: { [screen1] }, backdropFactory: { _ in conflict })
        var blockedConfig = configuration("backdrop-conflict"); blockedConfig.backdrop = backdropConfig
        try blockedPlayer.start(blockedConfig)
        try await wait { blockedPlayer.phase == .playing }
        await blockedPlayer.stop()
        check(blockedPlayer.restorationPending && blockedPlayer.error?.contains("fixture restore") == true && blockedPlayer.phase == .failed,
              "恢复失败在停止后保留错误与待恢复状态")
        let blockedBackend = SceneTestBackend()
        let blockedModel = LibraryModel(backend: blockedBackend, scenePlayer: blockedPlayer)
        await blockedModel.perform(.play("fixture.mp4"))
        check(await blockedBackend.actions.isEmpty && blockedModel.error != nil, "恢复失败阻止视频替换覆盖原配置")
        do { try blockedPlayer.start(configuration("must-not-start")); preconditionFailure("pending recovery bypassed") }
        catch { check(true, "关闭自动开关也不能绕过待恢复状态") }

        // Real Process/Pipe boundary with a fake helper and temporary journal.
        // Confirms Swift closes the last writer and waits for restoration.
        try FileManager.default.createDirectory(at: backdropConfig.state, withIntermediateDirectories: true)
        try #"""
        import pathlib, plistlib, sys
        state = pathlib.Path(sys.argv[sys.argv.index('--state-dir')+1])/'session.plist'
        image = pathlib.Path(sys.argv[sys.argv.index('lease')+1]) if 'lease' in sys.argv else None
        def save(value): state.write_bytes(plistlib.dumps({'state':value, 'image':str(image) if image else ''}))
        if 'lease' in sys.argv:
            assert image.exists()
            save('applied')
            print('BACKDROP_READY', flush=True)
            sys.stdin.buffer.read()
        save('restored')
        """#.write(to: backdropConfig.helper, atomically: true, encoding: .utf8)
        backdropConfig.sourcePackage = root.appendingPathComponent("wallpaper-A/scene.pkg")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 12,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let fixturePNG = bitmap.representation(using: .png, properties: [:])!
        let capturedA = try SceneBackdropCapture.capture(package: backdropConfig.sourcePackage!, state: backdropConfig.state) {
            try fixturePNG.write(to: $0)
        }
        let capturedB = try SceneBackdropCapture.capture(package: root.appendingPathComponent("wallpaper-B/scene.pkg"), state: backdropConfig.state) {
            try fixturePNG.write(to: $0)
        }
        check(capturedA.deletingLastPathComponent().deletingLastPathComponent() != capturedB.deletingLastPathComponent().deletingLastPathComponent(), "不同壁纸的底图目录完全隔离")
        check(try Data(contentsOf: capturedA).prefix(8) == Data([137,80,78,71,13,10,26,10]), "底图实际编码为PNG而非只修改后缀")
        let openingFolder = root.appendingPathComponent("opening-scene", isDirectory: true)
        try FileManager.default.createDirectory(at: openingFolder, withIntermediateDirectories: true)
        let openingPackage = openingFolder.appendingPathComponent("scene.pkg")
        try Data([1]).write(to: openingPackage)
        try Data(#"{"general":{"properties":{"opening":{"type":"bool","text":"开场动画 Intro Animation","value":true}}}}"#.utf8)
            .write(to: openingFolder.appendingPathComponent("project.json"))
        check(SceneBackdropFrameSampler.openingEnabled(package: openingPackage, values: [:]),
              "作者启用的开场动画默认延后静帧采样")
        check(!SceneBackdropFrameSampler.openingEnabled(package: openingPackage,
              values: ["opening": .boolean(false)]), "当前壁纸关闭开场后不拖慢静帧采样")
        func solid(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> Data {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 24,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let pixels = bitmap.bitmapData!
            for y in 0..<24 { for x in 0..<32 {
                let index = y * bitmap.bytesPerRow + x * 4
                pixels[index] = red; pixels[index + 1] = green; pixels[index + 2] = blue; pixels[index + 3] = 255
            } }
            return bitmap.representation(using: .png, properties: [:])!
        }
        let black = solid(0, 0, 0), red = solid(255, 0, 0), green = solid(0, 255, 0)
        let sampled = root.appendingPathComponent("sampled.heic")
        var samples = 0
        try SceneBackdropFrameSampler.capture(to: sampled, openingEnabled: false, sampleTimes: [0, 0]) { url in
            samples += 1
            try (samples == 1 ? black : red).write(to: url)
        }
        let selectedRed = try Data(contentsOf: sampled)
        check(samples == 2 && selectedRed == red,
              "黑色首帧不登记为底图，改用后续场景画面")
        try FileManager.default.removeItem(at: sampled)
        let darkScene = solid(15, 15, 15)
        samples = 0
        try SceneBackdropFrameSampler.capture(to: sampled, openingEnabled: false, sampleTimes: [0, 0]) { url in
            samples += 1
            try darkScene.write(to: url)
        }
        let selectedDark = try Data(contentsOf: sampled)
        check(samples == 1 && selectedDark == darkScene, "真实暗色场景不因低亮度被误判为黑色开场")
        try FileManager.default.removeItem(at: sampled)
        samples = 0
        try SceneBackdropFrameSampler.capture(to: sampled, openingEnabled: true, sampleTimes: [0, 0]) { url in
            samples += 1
            try (samples == 1 ? red : green).write(to: url)
        }
        let selectedGreen = try Data(contentsOf: sampled)
        check(samples == 2 && selectedGreen == green,
              "开场动画开启时即使首帧有内容也选开场后的帧")
        try FileManager.default.removeItem(at: sampled)
        do {
            try SceneBackdropFrameSampler.capture(to: sampled, openingEnabled: false, sampleTimes: [0, 0]) {
                try black.write(to: $0)
            }
            preconditionFailure("black-only scene registered")
        } catch {
            check(!FileManager.default.fileExists(atPath: sampled.path), "只有黑帧时拒绝覆盖系统墙纸")
        }
        do {
            _ = try SceneBackdropCapture.capture(package: backdropConfig.sourcePackage!, state: backdropConfig.state) { try Data("broken".utf8).write(to: $0) }
            preconditionFailure("bad image accepted")
        } catch { check(true, "截图无效时拒绝应用且不复用其他壁纸") }
        let realLease = SceneBackdropLease(configuration: backdropConfig)
        try realLease.activate(displayID: 1) { try fixturePNG.write(to: $0) }
        check(backdropConfig.recoveryPending, "底图进程准备好后恢复账本仍保留")
        try realLease.finish()
        check(!backdropConfig.recoveryPending, "关闭UI管道会等待子进程复原后返回")
        try realLease.finish()
        check(!backdropConfig.recoveryPending, "重复停止不会重新应用底图")
        let pendingJournal = try PropertyListSerialization.data(fromPropertyList: ["state":"pending_restore"], format: .binary, options: 0)
        try pendingJournal.write(to: backdropConfig.state.appendingPathComponent("session.plist"))
        try SceneBackdropLease.recover(backdropConfig)
        check(!backdropConfig.recoveryPending, "重启恢复入口处理遗留账本")
        // Interrupt a real isolated lease at the system activation boundary.
        // The injected callback never touches macOS Wallpaper settings.
        guard let display = NSScreen.screens.first,
              let displayID = (display.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        else { throw BackendError.message("Video backdrop checks require a display") }
        let video = root.appendingPathComponent("race.mp4")
        try Data([1]).write(to: video)
        let videoHelper = root.appendingPathComponent("video-helper.py")
        let helperSource = try String(contentsOf: backdropConfig.helper, encoding: .utf8)
        try helperSource.replacingOccurrences(of: "state = pathlib.Path", with:
            "if 'check-compatibility' in sys.argv:\n    print('WALLPAPER_COMPATIBILITY_OK'); sys.exit(0)\nstate = pathlib.Path")
            .write(to: videoHelper, atomically: true, encoding: .utf8)
        for operation in ["stop", "off", "shutdown", "normal"] {
            let state = root.appendingPathComponent("video-race-" + operation)
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            let settings = SceneBackdropConfiguration(helper: videoHelper, inventory: root, state: state)
            let gate = VideoActivationGate()
            let controller = VideoBackdropController(configuration: { settings }, runner: VideoFrameFixture(),
                activateSystemWallpaper: { _, _ in try await gate.enter() })
            let raceBackend = SceneTestBackend()
            let raceModel = LibraryModel(backend: raceBackend, videoBackdrop: controller)
            let activation = Task { try await controller.activate(video: video, preferences: .init(), displayID: displayID) }
            try await wait { gate.entered }
            check(settings.recoveryPending && controller.activePath == nil,
                  "视频\(operation)测试确实停在已建lease但尚未激活阶段")
            if operation == "normal" {
                gate.release()
                try await activation.value
                check(controller.activePath == video.path && gate.completed == 1, "未取消的视频底图正常完成激活")
                try await controller.stop()
            } else {
                var stopFinished = false
                var stopError: String?
                let stopping = Task {
                    do {
                        switch operation {
                        case "off": await raceModel.perform(.off)
                        case "shutdown": await raceModel.shutdownScene()
                        default: try await controller.stop()
                        }
                    } catch { stopError = error.localizedDescription }
                    stopFinished = true
                }
                try await wait { stopFinished || gate.cancelled }
                let returnedEarly = stopFinished
                gate.release()
                _ = try? await activation.value
                await stopping.value
                let leftActive = controller.activePath != nil || settings.recoveryPending
                // Clean up even on the old implementation before reporting failure.
                try? await controller.stop()
                check(!returnedEarly && !leftActive && gate.completed == 0 && stopError == nil,
                      "视频\(operation)取消并等待准备任务复原，不允许晚到激活")
                if operation == "shutdown" {
                    check(await raceBackend.actions == ["off"], "退出也会停止仍在准备底图的视频引擎")
                }
            }
            check(!settings.recoveryPending && !controller.transitioning && controller.activePath == nil,
                  "视频\(operation)完成后无恢复账本或过渡状态残留")
        }
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
@MainActor private final class DisplayFixture {
    var screens: [SceneDisplay]
    init(_ screens: [SceneDisplay]) { self.screens = screens }
}

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


private final class BackdropFixture: SceneBackdropControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var active = false
    private let failRestore: Bool
    init(failRestore: Bool = false) { self.failRestore = failRestore }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    var recoveryPending: Bool { lock.lock(); defer { lock.unlock() }; return active }
    func activate(displayID: UInt32, capture: (URL) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        active = true; recorded.append("apply:\(displayID)")
    }
    func checkHealth() throws { }
    func finish() throws {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        if failRestore { throw BackendError.message("fixture restore failure") }
        recorded.append("restore"); active = false
    }
}

@MainActor private final class VideoActivationGate {
    var entered = false
    var cancelled = false
    var completed = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func enter() async throws {
        entered = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation = $0 }
        } onCancel: {
            Task { @MainActor in self.cancelled = true }
        }
        try Task.checkCancellation()
        completed += 1
    }
    func release() { continuation?.resume(); continuation = nil }
}

private struct VideoFrameFixture: CommandExecuting {
    func run(_ executable: String, _ args: [String], timeout: Double) async throws -> CommandResult {
        let filter = args[args.firstIndex(of: "-vf")! + 1]
        let fields = filter.split(separator: ":")
        let width = Int(fields[0].dropFirst("scale=".count))!, height = Int(fields[1])!
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args.last!))
        return CommandResult(code: 0, text: "")
    }
}
