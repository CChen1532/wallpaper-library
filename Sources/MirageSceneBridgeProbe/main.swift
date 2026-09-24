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
    print("selftest: lifecycle, JSON control, failure detection, and child cleanup passed")
}

private func verifyRuntime(_ path: String) throws {
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
    require(process.terminationStatus == 0 && help.contains("--control-stdin") && help.contains("--deferred-show"), "渲染器控制接口不匹配")
    print("runtime: renderer, assets, Vulkan ICD, frameworks, and CLI contract verified")
}

private func trial(_ arguments: [String]) throws {
    guard arguments.count == 5, arguments[4] == "--consent",
          let displayID = UInt32(arguments[3]) else {
        fail("试验格式：--trial <Mirage.app> <scene.pkg> <displayID> --consent")
    }
    let runtime = try MirageSceneRuntime(app: URL(fileURLWithPath: arguments[1], isDirectory: true))
    let scene = URL(fileURLWithPath: arguments[2])
    let rendererArguments = try runtime.trialArguments(scenePackage: scene, displayID: displayID)
    require(NSScreen.screens.contains { screen in
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
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
    print("trial: activated on display \(displayID); stopping after 5 seconds")
    fflush(stdout)
    Thread.sleep(forTimeInterval: 5)
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
    case "--trial":
        try trial(Array(arguments.dropFirst()))
    default:
        fail("可用命令：--selftest | --verify-runtime <Mirage.app> | --trial <Mirage.app> <scene.pkg> <displayID> --consent")
    }
} catch {
    fail(error.localizedDescription)
}
