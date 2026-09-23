import Foundation

/// Opt-in integration test. Refuses to interrupt existing playback/rotation.
@main struct LiveControls {
    static func main() async throws {
        let backend = PhontoBackend()
        let baseline = try await backend.state()
        guard !baseline.running && !baseline.rotating else {
            throw BackendError.message("真实控制测试要求开始时未播放且轮播关闭，以免打断现有工作。")
        }
        let cache = backend.home.appendingPathComponent(".cache/phonto/current")
        let originalCache = try? Data(contentsOf: cache)
        let items = try await backend.library()
        guard items.count >= 2 else { throw BackendError.message("需要至少两个有效素材") }
        var failure: Error?
        var count = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw BackendError.message("FAIL: " + name) }
            count += 1
            print("PASS: " + name)
        }
        do {
            try await backend.perform(.play(items[0].id))
            try check(try await backend.state().currentPath == items[0].id, "启动指定路径")
            try await backend.perform(.next)
            try check(try await backend.state().currentPath == items[1].id, "下一张")
            try await backend.perform(.previous)
            try check(try await backend.state().currentPath == items[0].id, "上一张")
            try await backend.perform(.random)
            let random = try await backend.state()
            try check(random.currentPath != items[0].id && random.running, "随机排除当前")
            try await backend.perform(.stop)
            try check(try await backend.state().running == false, "停止播放")
            try await backend.perform(.rotation(60, "rand"))
            try await backend.perform(.stop)
            let stopped = try await backend.state()
            try check(!stopped.running && stopped.rotating && stopped.interval == 60, "停止保留轮播")
            print("等待 60 秒定时轮播触发（最长 90 秒）…")
            let deadline = ContinuousClock.now.advanced(by: .seconds(90))
            var automatic = PlaybackState()
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: .seconds(3))
                automatic = try await backend.state()
                if automatic.running && automatic.currentPath != nil { break }
            }
            try check(automatic.running && automatic.rotating, "launchd定时轮播实际触发")
            try await backend.perform(.stopRotation)
            let withoutRotation = try await backend.state()
            try check(withoutRotation.running && !withoutRotation.rotating, "关闭轮播保留播放")
        } catch { failure = error }
        // Always restore the initial off state, including when an assertion fails.
        try await backend.perform(.off)
        if let originalCache { try originalCache.write(to: cache, options: .atomic) }
        else if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
        let restored = try await backend.state()
        try check(!restored.running && !restored.rotating, "恢复未播放且轮播关闭")
        if let failure { throw failure }
        print("\(count) live control checks passed; baseline restored")
    }
}
