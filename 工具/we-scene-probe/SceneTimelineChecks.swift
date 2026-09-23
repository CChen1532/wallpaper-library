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

    var clock = try WEScenePlaybackClock(durationSeconds: 2)
    c.check(try !clock.isPlaying && clock.sourceSeconds(at: 10) == 0, "初始暂停且播放头为零")
    try clock.play(at: 10)
    c.check(try clock.isPlaying && clock.sourceSeconds(at: 10.5) == 0.5, "单调时钟驱动播放头")
    try clock.pause(at: 11)
    c.check(try !clock.isPlaying && clock.sourceSeconds(at: 15) == 1, "暂停期间播放头不前进")
    try clock.play(at: 20)
    c.check(try clock.sourceSeconds(at: 21.5) == 0.5, "恢复后累计时长并在边界循环")
    try clock.stop(at: 22)
    c.check(try !clock.isPlaying && clock.sourceSeconds(at: 30) == 0, "停止归零且保持暂停")
    c.check(rejects { _ = try clock.sourceSeconds(at: 21) } &&
            rejects { try clock.play(at: .nan) }, "倒退或非有限单调时间拒绝")
}
