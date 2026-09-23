import Foundation

/// A deterministic playhead driven by a caller-supplied monotonic clock.
/// It has no timer, display link, decoder, audio, or desktop window of its own.
public struct WEScenePlaybackClock {
    public let durationSeconds: Double
    private var accumulatedSeconds: Double = 0
    private var runningSince: Double?
    private var lastObservedSeconds: Double = 0

    public var isPlaying: Bool { runningSince != nil }

    public init(durationSeconds: Double) throws {
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw ProbeError.invalid("播放时钟需要正有限视频时长")
        }
        self.durationSeconds = durationSeconds
    }

    private func validTime(_ seconds: Double) throws {
        guard seconds.isFinite, seconds >= 0, seconds >= lastObservedSeconds else {
            throw ProbeError.invalid("播放时钟要求不倒退的单调秒数")
        }
    }

    public mutating func play(at monotonicSeconds: Double) throws {
        try validTime(monotonicSeconds)
        if runningSince == nil { runningSince = monotonicSeconds }
        lastObservedSeconds = monotonicSeconds
    }

    public mutating func pause(at monotonicSeconds: Double) throws {
        try validTime(monotonicSeconds)
        if let start = runningSince {
            let next = accumulatedSeconds + (monotonicSeconds - start)
            guard next.isFinite else { throw ProbeError.invalid("播放时钟累计时间溢出") }
            accumulatedSeconds = next
            runningSince = nil
        }
        lastObservedSeconds = monotonicSeconds
    }

    public mutating func stop(at monotonicSeconds: Double) throws {
        try validTime(monotonicSeconds)
        accumulatedSeconds = 0
        runningSince = nil
        lastObservedSeconds = monotonicSeconds
    }

    public mutating func sourceSeconds(at monotonicSeconds: Double) throws -> Double {
        try validTime(monotonicSeconds)
        let elapsed = accumulatedSeconds + (runningSince.map { monotonicSeconds - $0 } ?? 0)
        guard elapsed.isFinite, elapsed >= 0 else { throw ProbeError.invalid("播放时钟时间溢出") }
        let source = elapsed.truncatingRemainder(dividingBy: durationSeconds)
        guard source.isFinite, source >= 0, source < durationSeconds else {
            throw ProbeError.invalid("播放时钟循环时间非法")
        }
        lastObservedSeconds = monotonicSeconds
        return source
    }
}
