import Foundation
import AppKit
import MirageSceneBridge

private func fail(_ message: String) -> Never {
    fputs("MirageSceneBridgeProbe: \(message)\n", stderr)
    exit(2)
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fail(message) }
}

private func selfTest() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-bridge-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let script = folder.appendingPathComponent("fake-renderer.sh")
    let body = """
    printf '%s\\n' '{"event":"scene-ready"}' '{"event":"first-frame-presented"}'
    while IFS= read -r command; do
      case "$command" in
        '{"cmd":"activate"}') printf '%s\\n' '{"event":"activated"}' ;;
        '{"cmd":"deactivate"}') printf '%s\\n' '{"event":"deactivated"}' ;;
        '{"cmd":"moveDisplay","displayID":3}') printf '%s\\n' '{"event":"display-moved","display_id":3}' ;;
        '{"cmd":"moveDisplay","displayID":4}') printf '%s\\n' '{"event":"display-move-failed","display_id":4}' ;;
        '{"cmd":"quit"}') exit 0 ;;
        *) exit 4 ;;
      esac
    done
    """
    try body.write(to: script, atomically: true, encoding: .utf8)
    let child = MirageSceneChild(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [script.path])
    try child.start()
    try child.wait(for: "scene-ready", timeout: 2)
    try child.wait(for: "first-frame-presented", timeout: 2)
    try child.send("activate")
    try child.wait(for: "activated", timeout: 2)
    try child.move(to: 3)
    try child.waitForMove(to: 3, timeout: 2)
    try child.move(to: 4)
    do {
        try child.waitForMove(to: 4, timeout: 2)
        fail("跨屏移动失败未被识别")
    } catch is MirageSceneBridgeError { }
    child.stop()
    require(child.terminationStatus == 0, "假渲染器未收到退出命令")
    let failureScript = folder.appendingPathComponent("failed-renderer.sh")
    try "printf '%s\\n' '{\"event\":\"activation-failed\"}'\nexit 0\n"
        .write(to: failureScript, atomically: true, encoding: .utf8)
    let failed = MirageSceneChild(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [failureScript.path])
    try failed.start()
    do {
        try failed.wait(for: "activated", timeout: 2)
        fail("激活失败未被识别")
    } catch is MirageSceneBridgeError {
        failed.stop()
    }
    let closedScript = folder.appendingPathComponent("closed-stdin.sh")
    try "exec 0<&-\nprintf '%s\\n' '{\"event\":\"scene-ready\"}'\nsleep 2\n"
        .write(to: closedScript, atomically: true, encoding: .utf8)
    let closed = MirageSceneChild(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [closedScript.path])
    try closed.start()
    try closed.wait(for: "scene-ready", timeout: 2)
    do {
        try closed.send("activate")
        fail("关闭的控制管道未返回写入错误")
    } catch {
        closed.stop()
    }
    let screens = [FocusScreen(displayID: 1, bounds: CGRect(x: 0, y: 0, width: 100, height: 100)),
                   FocusScreen(displayID: 3, bounds: CGRect(x: 100, y: 0, width: 100, height: 100))]
    let windows = [FocusWindow(ownerPID: 7, layer: 0, alpha: 1,
                               bounds: CGRect(x: 120, y: 5, width: 60, height: 60))]
    require(FocusDisplaySelector.choose(frontmostPID: 7, windows: windows,
                                        screens: screens, cursorDisplayID: 1) == 3,
            "焦点窗口应优先于鼠标位置")
    require(FocusDisplaySelector.choose(frontmostPID: 8, windows: windows,
                                        screens: screens, cursorDisplayID: 1) == 1,
            "无焦点窗口时应回退至鼠标所在屏")
    var dwell = FocusDisplayDwell(currentDisplayID: 1)
    require(dwell.observe(3) == nil && dwell.observe(3) == 3 &&
            dwell.observe(1) == nil && dwell.observe(3) == nil,
            "跨屏目标应消抖，且目标改变须重新计数")
    print("selftest: lifecycle, display move, focus routing, failed activation, closed stdin, and cleanup passed")
}

private func verifyRuntime(_ path: String, requireFocusFollow: Bool = false) throws {
    let runtime = try MirageSceneRuntime(app: URL(fileURLWithPath: path, isDirectory: true))
    let process = Process()
    process.executableURL = runtime.executable
    process.arguments = ["--help"]
    process.environment = runtime.environment()
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let help = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    require(process.terminationStatus == 0 && help.contains("--control-stdin") &&
            help.contains("--deferred-show") &&
            (!requireFocusFollow || help.contains("--follow-focus")), "渲染器控制接口不匹配")
    print("runtime: renderer, assets, Vulkan ICD, frameworks, and CLI contract verified")
}

private func samplePerformance(pid: Int32, elapsedSeconds: Int) throws {
    let command = Process()
    command.executableURL = URL(fileURLWithPath: "/bin/ps")
    command.arguments = ["-p", String(pid), "-o", "%cpu=,rss=,time="]
    let output = Pipe()
    command.standardOutput = output
    command.standardError = FileHandle.nullDevice
    try command.run()
    command.waitUntilExit()
    guard command.terminationStatus == 0 else {
        throw MirageSceneBridgeError.failed("性能采样无法读取渲染进程")
    }
    let fields = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(whereSeparator: \.isWhitespace)
    guard fields.count == 3, let cpu = Double(fields[0]), let rssKiB = Int(fields[1]) else {
        throw MirageSceneBridgeError.failed("性能采样输出格式异常")
    }
    print(String(format: "perf_sample elapsed=%ds cpu=%.1f%% rss=%.1fMiB cputime=%@",
                 elapsedSeconds, cpu, Double(rssKiB) / 1024, String(fields[2])))
    fflush(stdout)
}

private func trial(_ arguments: [String], durationSeconds: Int,
                   collectPerformance: Bool = false, followFocus: Bool = false) throws {
    guard arguments.count == 5, arguments[4] == "--consent",
          let displayID = UInt32(arguments[3]) else {
        fail("试验格式：<Mirage运行目录> <scene.pkg> <displayID> --consent")
    }
    let runtime = try MirageSceneRuntime(app: URL(fileURLWithPath: arguments[1], isDirectory: true))
    if followFocus { try verifyRuntime(arguments[1], requireFocusFollow: true) }
    let scene = URL(fileURLWithPath: arguments[2])
    let initialDisplayID = followFocus ? (FocusDisplaySelector.currentDisplay() ?? displayID) : displayID
    let rendererArguments = try runtime.trialArguments(scenePackage: scene,
                                                        displayID: initialDisplayID,
                                                        durationSeconds: durationSeconds,
                                                        followFocus: followFocus)
    require(NSScreen.screens.contains { screen in
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == initialDisplayID
    }, "目标显示器当前未连接或工具会话无法读取显示器")
    let phonto = Process()
    phonto.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    phonto.arguments = ["phonto-wall", "status"]
    let statusOutput = Pipe()
    phonto.standardOutput = statusOutput
    phonto.standardError = statusOutput
    try phonto.run()
    phonto.waitUntilExit()
    let status = String(decoding: statusOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    require(phonto.terminationStatus == 0 && status.contains("未运行") && status.contains("未开启"),
            "phonto-wall 未确认处于停止且轮播关闭状态")
    let child = MirageSceneChild(executable: runtime.executable, arguments: rendererArguments, environment: runtime.environment())
    try child.start()
    defer { child.stop() }
    try child.wait(for: "scene-ready", timeout: 60)
    try child.wait(for: "first-frame-presented", timeout: 15)
    try child.send("activate")
    try child.wait(for: "activated", timeout: 5)
    print("trial: activated on display \(initialDisplayID); stopping after \(durationSeconds) seconds")
    fflush(stdout)
    let start = ProcessInfo.processInfo.systemUptime
    let deadline = start + Double(durationSeconds)
    var nextSample = start
    var nextFocusCheck = start
    var focusDwell = FocusDisplayDwell(currentDisplayID: initialDisplayID)
    while ProcessInfo.processInfo.systemUptime < deadline {
        if let status = child.terminationStatus {
            throw MirageSceneBridgeError.failed("Mirage Scene 在试验期间提前退出（\(status)）")
        }
        let now = ProcessInfo.processInfo.systemUptime
        if followFocus && now >= nextFocusCheck {
            if let target = focusDwell.observe(FocusDisplaySelector.currentDisplay()) {
                try child.move(to: target)
                try child.waitForMove(to: target, timeout: 2)
                print("focus_route: display=\(target)")
                fflush(stdout)
            }
            nextFocusCheck = ProcessInfo.processInfo.systemUptime + 0.25
        }
        if collectPerformance && now >= nextSample {
            try samplePerformance(pid: child.processIdentifier, elapsedSeconds: Int((now - start).rounded()))
            nextSample += 5
        }
        let remainingToEnd = deadline - ProcessInfo.processInfo.systemUptime
        let remainingToSample = collectPerformance ? nextSample - ProcessInfo.processInfo.systemUptime : 1
        let remainingToFocus = followFocus ? nextFocusCheck - ProcessInfo.processInfo.systemUptime : 1
        Thread.sleep(forTimeInterval: max(0, min(1, min(remainingToSample, remainingToEnd, remainingToFocus))))
    }
    if collectPerformance { try samplePerformance(pid: child.processIdentifier, elapsedSeconds: durationSeconds) }
    child.stop()
    require(child.terminationStatus == 0, "渲染器未正常退出")
    print("trial: stopped cleanly")
}

do {
    let arguments = CommandLine.arguments
    switch arguments.dropFirst().first {
    case "--selftest" where arguments.count == 2:
        try selfTest()
    case "--verify-runtime" where arguments.count == 3:
        try verifyRuntime(arguments[2])
    case "--verify-follow-runtime" where arguments.count == 3:
        try verifyRuntime(arguments[2], requireFocusFollow: true)
    case "--focus-diagnose" where arguments.count == 2:
        let ids = NSScreen.screens.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
        let selection = FocusDisplaySelector.currentSelection()
        print("focus: connected=\(ids) selected=\(selection.displayID.map(String.init) ?? "unknown") source=\(selection.source.rawValue)")
    case "--trial":
        try trial(Array(arguments.dropFirst()), durationSeconds: 5)
    case "--space-trial":
        try trial(Array(arguments.dropFirst()), durationSeconds: 60)
    case "--perf-trial":
        try trial(Array(arguments.dropFirst()), durationSeconds: 60, collectPerformance: true)
    case "--follow-trial":
        try trial(Array(arguments.dropFirst()), durationSeconds: 60,
                  collectPerformance: true, followFocus: true)
    default:
        fail("可用命令：--selftest | --focus-diagnose | --verify-runtime/--verify-follow-runtime <Mirage运行目录> | --trial/--space-trial/--perf-trial/--follow-trial <Mirage运行目录> <scene.pkg> <displayID> --consent")
    }
} catch {
    fail(error.localizedDescription)
}
