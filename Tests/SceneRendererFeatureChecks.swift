import AppKit
import Foundation
import ImageIO

@main struct SceneRendererFeatureChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); count += 1; print("PASS: \(message)")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("library-a/same/scene.pkg")
        let b = root.appendingPathComponent("library-b/same/scene.pkg")
        let old = Data(#"{"fps":60,"cropMode":"left","mouseEnabled":false,"mouseButtonsEnabled":false,"inputHz":120,"followsDisplay":false,"soundEnabled":true,"audioResponseEnabled":true}"#.utf8)
        let decoded = try JSONDecoder().decode(ScenePreferences.self, from: old)
        check(decoded.fps == 60 && !decoded.mouseEnabled && decoded.inputHz == 120 && decoded.soundEnabled, "旧设置保留原播放偏好")
        check(decoded.volume == 1 && decoded.speed == 1 && decoded.renderScale == 1 && !decoded.metalFX && decoded.msaa == 1, "旧设置补齐保守画质默认值")
        check(!decoded.energySaving && !decoded.pauseWhenCovered && !decoded.mediaInfoEnabled && !decoded.shortcutsEnabled, "新自动化与媒体功能不擅自开启")
        check(try JSONDecoder().decode(ScenePreferences.self, from: JSONEncoder().encode(decoded)) == decoded, "设置编解码往返不丢失字段")
        var bad = ScenePreferences()
        bad.volume = .nan; bad.speed = -.infinity; bad.renderScale = 0; bad.msaa = 3; bad.fillMode = "invalid"
        let normalized = ScenePreferencesStore.normalized(bad)
        check(normalized.volume == 1 && normalized.speed == 1 && normalized.renderScale == 0.25 && normalized.msaa == 1 && normalized.fillMode == "cover", "异常播放和画质值有界归一化")
        var live = decoded
        live.fps = 120; live.volume = 0.3; live.fillMode = "stretch"; live.cropMode = "custom"; live.positionY = 0.8
        check(live.canUpdateLive(from: decoded), "播放参数更改允许复用会话")
        live.metalFX = true
        check(!live.canUpdateLive(from: decoded), "MetalFX更改需要新会话")
        live = decoded; live.msaa = 4
        check(!live.canUpdateLive(from: decoded), "MSAA更改需要新会话")
        live = decoded; live.mouseEnabled.toggle()
        check(!live.canUpdateLive(from: decoded), "输入策略更改保留重启路径")
        var power = ScenePreferences(); power.fps = 60; power.energySaving = true; power.pauseWhenCovered = true
        check(ScenePowerDecision.resolve(power, manualPause: false, environment: .init()).state == "run", "正常环境正常播放")
        check(ScenePowerDecision.resolve(power, manualPause: false, environment: .init(onBattery: true)).fps == 15, "电池环境降帧")
        check(ScenePowerDecision.resolve(power, manualPause: false, environment: .init(lowPower: true)).state == "throttle", "系统低功耗模式降帧")
        check(ScenePowerDecision.resolve(power, manualPause: false, environment: .init(thermal: 2)).state == "throttle", "高温降帧")
        check(ScenePowerDecision.resolve(power, manualPause: false, environment: .init(thermal: 3)).state == "pause", "严重高温暂停")
        check(ScenePowerDecision.resolve(power, manualPause: false, environment: .init(covered: true)).state == "pause", "前台窗口覆盖暂停")
        check(ScenePowerDecision.resolve(power, manualPause: true, environment: .init()).state == "pause", "自动限制解除后保留手动暂停")
        power.energySaving = false; power.pauseWhenCovered = false
        check(ScenePowerDecision.resolve(power, manualPause: false, environment: .init(onBattery: true, thermal: 3, covered: true)).state == "run", "逐壁纸关闭自动策略后不被其他策略影响")
        check(SceneShortcut.target("https://example.com/path") != nil && SceneShortcut.target("javascript:alert(1)") == nil && SceneShortcut.target("file:///bin/sh") == nil, "快捷入口仅允许明确的网址及安全文件类型")
        check(SceneShortcut.target("https://user:password@example.com") == nil, "快捷入口拒绝携带凭证的网址")
        let document = root.appendingPathComponent("note.txt"); try Data("hello".utf8).write(to: document)
        check(SceneShortcut.target(document.path) == document, "可打开用户选择的普通文档")
        let executable = root.appendingPathComponent("run.command"); try Data("exit 0".utf8).write(to: executable)
        check(SceneShortcut.target(executable.path) == nil, "脚本文件不会被快捷入口执行")
        let legacy = root.appendingPathComponent("old.json"); try Data(#"{"counter":"7"}"#.utf8).write(to: legacy)
        let folderA = try SceneScriptStorage.prepare(package: a, root: root.appendingPathComponent("storage"), legacy: legacy)
        let folderB = try SceneScriptStorage.prepare(package: b, root: root.appendingPathComponent("storage"), legacy: legacy)
        check(folderA != folderB, "同名素材目录的脚本数据按完整路径隔离")
        let migrated = folderA.appendingPathComponent("same.json")
        check(try Data(contentsOf: migrated) == Data(contentsOf: legacy), "首次迁移保留旧脚本数据")
        try Data(#"{"counter":"8"}"#.utf8).write(to: migrated)
        _ = try SceneScriptStorage.prepare(package: a, root: root.appendingPathComponent("storage"), legacy: legacy)
        check(try String(contentsOf: migrated, encoding: .utf8).contains("8"), "重复迁移不会覆盖新数据")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = root.appendingPathComponent("source.png"); try bitmap.representation(using: .png, properties: [:])!.write(to: image)
        let importedA = try SceneImageImport.importImage(image, for: a, directory: root.appendingPathComponent("images"))
        let importedB = try SceneImageImport.importImage(image, for: b, directory: root.appendingPathComponent("images"))
        check(importedA != importedB && FileManager.default.fileExists(atPath: image.path), "自定义图片按素材隔离且保留原文件")
        check(CGImageSourceCreateWithURL(importedA as CFURL, nil) != nil, "导入图片可由ImageIO解码")
        do { _ = try SceneImageImport.importImage(document, for: a); preconditionFailure("non-image accepted") }
        catch { check(true, "非图片文件不会送入纹理通道") }
        try FileManager.default.createDirectory(at: a.deletingLastPathComponent(), withIntermediateDirectories: true)
        let manifest: [String: Any] = ["general": ["properties": [
            "picture": ["type": "file", "text": "Picture", "value": ""],
            "shortcut": ["type": "usershortcut", "text": "Shortcut", "value": "https://example.com"]
        ]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: a.deletingLastPathComponent().appendingPathComponent("project.json"))
        let catalog = ScenePropertyCatalog.load(for: a)
        check(catalog.properties.count == 2 && catalog.properties.contains { $0.kind == .imageFile } && catalog.properties.contains { $0.kind == .shortcut }, "识别图片与快捷入口属性")
        let launch = try ScenePropertyLaunch.prepare(package: a, catalog: catalog, savedData: JSONSerialization.data(withJSONObject: ["picture": importedA.path]), directory: root.appendingPathComponent("properties"))
        let overrides = try JSONSerialization.jsonObject(with: Data(contentsOf: launch.file!)) as! [String: Any]
        check((overrides["picture"] as? [String: String])?["type"] == "scenetexture", "file图片属性规范为渲染器纹理描述")
        let media = SceneMediaProvider(directory: root.appendingPathComponent("artwork"))
        let payload = try await media.payload(["title": "Track", "artist": "Artist", "playing": true, "position": 4.0, "duration": 30.0, "artworkData": Data(contentsOf: image).base64EncodedString()])!
        let decodedMedia = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        check(decodedMedia["title"] as? String == "Track" && decodedMedia["state"] as? Int == 1, "媒体信息转为渲染器协议")
        check(FileManager.default.fileExists(atPath: decodedMedia["artURL"] as! String), "媒体封面使用本地有界缓存")
        let next = try await media.payload(["title": "Next", "duration": Double.nan])!
        let decodedNext = try JSONSerialization.jsonObject(with: next) as! [String: Any]
        check(decodedNext["artURL"] as? String == "" && decodedNext["duration"] as? Double == 0, "切换歌曲不沿用旧封面且拒绝非有限时间")
        let stale = try await media.payload(["title": "Paused", "duration": 30.0, "position": 90.0])!
        check((try JSONSerialization.jsonObject(with: stale) as? [String: Any])?["position"] as? Double == 30, "系统过期媒体进度限制在歌曲时长内")
        let fixture = root.appendingPathComponent("controls.py")
        try #"""
        import sys,json,shutil
        state={"counter":"7"}
        print('{"event":"scene-ready"}',flush=True)
        print('{"event":"first-frame-presented"}',flush=True)
        for line in sys.stdin:
            command=json.loads(line);cmd=command.get('cmd')
            if cmd=='activate': print('{"event":"activated"}',flush=True)
            elif cmd=='deactivate': print('{"event":"deactivated"}',flush=True)
            elif cmd=='exportScriptStorage': print(json.dumps(dict(event='script-storage',token=command['token'],values=state)),flush=True)
            elif cmd=='resetScriptStorage': state={}
            elif cmd=='snapshot':
                shutil.copyfile(sys.argv[1],command['path'])
                print(json.dumps(dict(event='snapshot-done',token=command['token'],ok=True)),flush=True)
            elif cmd=='quit': break
        """#.write(to: fixture, atomically: true, encoding: .utf8)
        let player = ScenePlayer(focusProvider: { 1 }, displayProvider: { [SceneDisplay(id: 1, uuid: "test", name: "Test")] })
        var config = SceneLaunchConfiguration(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [fixture.path, image.path], environment: nil, package: a, title: "Fixture", displayID: 1)
        config.supportsLiveProperties = true
        try player.start(config)
        for _ in 0..<100 where player.phase != .playing { try await Task.sleep(for: .milliseconds(30)) }
        check(player.phase == .playing, "控制导出测试会话启动")
        let exported = root.appendingPathComponent("export.json")
        try await player.export(.storage(exported), for: a)
        check(try JSONSerialization.jsonObject(with: Data(contentsOf: exported)) as? [String: String] == ["counter":"7"], "脚本数据导出通过实际控制管道接收JSON")
        let backup = root.appendingPathComponent("backup.json")
        try await player.export(.resetStorage(backup), for: a)
        try await player.export(.storage(exported), for: a)
        check(try JSONSerialization.jsonObject(with: Data(contentsOf: backup)) as? [String: String] == ["counter":"7"] && JSONSerialization.jsonObject(with: Data(contentsOf: exported)) as? [String: String] == [:], "重置先保存可恢复备份再清空隔离会话")
        do { try await player.export(.storage(exported), for: b); preconditionFailure("cross-scene export accepted") }
        catch { check(true, "导出拒绝已切换到另一张壁纸的请求") }
        player.togglePause()
        for _ in 0..<50 where !player.effectivePaused { try await Task.sleep(for: .milliseconds(30)) }
        let exportedImage = root.appendingPathComponent("frame.png")
        try await player.export(.screenshot(exportedImage), for: a)
        check(CGImageSourceCreateWithURL(exportedImage as CFURL, nil) != nil && player.manualPause, "暂停时的画面导出转为有效PNG且保留暂停意图")
        await player.stop()
        check(!player.exporting && player.phase == .stopped, "导出完成后停止没有残留操作状态")
        print("\(count) renderer feature checks passed")
    }
}
