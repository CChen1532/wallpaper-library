import Foundation

func runTimelineChecks(_ c: inout Checker) throws {
    func rejects(_ block: () throws -> Void) -> Bool { do { try block(); return false } catch { return true } }
    let timeline = try WESceneOfflineTimeline(framesPerSecond: 2, durationSeconds: 2)
    let times = try (0...4).map { try timeline.sourceSeconds(forFrame: $0) }
    c.check(times == [0, 0.5, 1, 1.5, 0], "离线序列按帧率映射并在时长边界循环")
    let short = try WESceneOfflineTimeline(framesPerSecond: 2, durationSeconds: 0.75)
    c.check(abs(try short.sourceSeconds(forFrame: 2) - 0.25) < 0.000001,
            "非整帧时长循环后保留余量")
    c.check(rejects { _ = try WESceneOfflineTimeline(framesPerSecond: 0, durationSeconds: 2) } &&
            rejects { _ = try WESceneOfflineTimeline(framesPerSecond: .nan, durationSeconds: 2) } &&
            rejects { _ = try WESceneOfflineTimeline(framesPerSecond: 61, durationSeconds: 2) },
            "非法帧率拒绝")
    c.check(rejects { _ = try WESceneOfflineTimeline(framesPerSecond: 30, durationSeconds: 0) } &&
            rejects { _ = try WESceneOfflineTimeline(framesPerSecond: 30, durationSeconds: .infinity) },
            "非法时长拒绝")
    c.check(rejects { _ = try timeline.sourceSeconds(forFrame: -1) } &&
            rejects { _ = try timeline.sourceSeconds(forFrame: 121) },
            "离线序列帧号有界")
}
