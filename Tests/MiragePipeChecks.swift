import Foundation

@main struct MiragePipeChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-pipe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("stalled.py")
        try """
        import time
        print('{"event":"scene-ready"}', flush=True)
        time.sleep(6)
        """.write(to: script, atomically: true, encoding: .utf8)
        let child = MirageSceneChild(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", script.path])
        try child.start()
        defer { child.stop() }
        try child.wait(for: "scene-ready", timeout: 2)
        let writer = Task.detached { () -> Bool in
            do {
                for index in 0..<64 {
                    try child.control(["cmd": "mediaStatus", "data": ["index": index, "value": String(repeating: "x", count: 32_000)]])
                }
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        try await Task.sleep(for: .milliseconds(150))
        let began = ContinuousClock.now
        writer.cancel()
        let cancelled = await writer.value
        let elapsed = ContinuousClock.now - began
        child.stop()
        precondition(cancelled && elapsed < .seconds(2), "stalled stdin must not prevent command cancellation")
        print("PASS: blocked renderer control write cancels within two seconds")

        let timedScript = root.appendingPathComponent("timed.py")
        try """
        import time
        print('{"event":"scene-ready"}', flush=True)
        time.sleep(12)
        """.write(to: timedScript, atomically: true, encoding: .utf8)
        let timedChild = MirageSceneChild(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", timedScript.path])
        try timedChild.start()
        defer { timedChild.stop() }
        try timedChild.wait(for: "scene-ready", timeout: 2)
        let timeoutBegan = ContinuousClock.now
        var timedOut = false
        do {
            for index in 0..<64 {
                try timedChild.control(["cmd": "mediaStatus", "data": ["index": index, "value": String(repeating: "x", count: 32_000)]])
            }
        } catch let failure as MirageSceneBridgeError {
            timedOut = failure.localizedDescription.contains("超时")
        }
        let timeoutElapsed = ContinuousClock.now - timeoutBegan
        timedChild.stop()
        precondition(timedOut && timeoutElapsed < .seconds(8), "stalled command writes must time out without cancellation")
        print("PASS: a stalled renderer cannot leave an uncancelled write waiting indefinitely")

        let readerScript = root.appendingPathComponent("reader.py")
        try """
        import json, sys
        print('{"event":"scene-ready"}', flush=True)
        received = 0
        for line in sys.stdin:
            command = json.loads(line)
            name = command['cmd']
            if name == 'mediaStatus':
                assert command['data']['index'] == received
                assert command['data']['value'] == '壁纸😀' * 4096
                received += 1
                if received == 64:
                    print('{"event":"all-written"}', flush=True)
            elif name == 'deactivate':
                print('{"event":"deactivated"}', flush=True)
            elif name == 'quit':
                break
            else:
                raise ValueError(name)
        """.write(to: readerScript, atomically: true, encoding: .utf8)
        let reader = MirageSceneChild(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", readerScript.path])
        try reader.start()
        defer { reader.stop() }
        try reader.wait(for: "scene-ready", timeout: 2)
        for index in 0..<64 {
            try reader.control(["cmd": "mediaStatus", "data": ["index": index, "value": String(repeating: "壁纸😀", count: 4096)]])
        }
        try reader.wait(for: "all-written", timeout: 2)
        reader.stop()
        precondition(reader.terminationStatus == 0, "chunked writes must preserve ordered complete UTF-8 JSON commands")
        print("PASS: 64 large UTF-8 commands arrive complete and in order")
        print("3 renderer pipe checks passed")
    }
}
