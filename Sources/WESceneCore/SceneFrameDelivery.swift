import Foundation

/// A single frame source. This contract does not create a window or alter a wallpaper.
public protocol WESceneFrameSource: Sendable {
    func play() async throws
    func poll(maxDimension: Int) async throws -> WESceneRealtimeSceneFrame?
    func close() async
}

extension WESceneRealtimeSceneSession: WESceneFrameSource {}

/// Delivery is serial: the producer waits for accept before requesting another frame.
public protocol WESceneFrameSink: Sendable {
    func accept(_ frame: WESceneRealtimeSceneFrame) async throws
    func finish() async
}

public struct WESceneFrameDeliveryLimits: Sendable {
    public let durationSeconds: Double
    public let pollHz: Int
    public let maxDimension: Int
    public let maxFrames: Int

    public init(durationSeconds: Double, pollHz: Int, maxDimension: Int, maxFrames: Int) throws {
        guard durationSeconds.isFinite, (0.1...300).contains(durationSeconds),
              (2...30).contains(pollHz), (1...960).contains(maxDimension),
              (1...3000).contains(maxFrames) else {
            throw ProbeError.invalid("无窗口帧交付限额无效")
        }
        self.durationSeconds = durationSeconds
        self.pollHz = pollHz
        self.maxDimension = maxDimension
        self.maxFrames = maxFrames
    }
}

public enum WESceneFrameDeliveryStopReason: String, Sendable {
    case durationLimit
    case frameLimit
    case requested
}

public struct WESceneFrameDeliverySummary: Sendable {
    public let pollAttempts: Int
    public let deliveredFrames: Int
    public let elapsedSeconds: Double
    public let stopReason: WESceneFrameDeliveryStopReason
}

/// One-shot, bounded bridge for a future display sink. It is not a desktop player.
/// A slow or stuck source/sink cannot be preempted mid-call; limits are checked between calls.
public actor WESceneFrameDelivery {
    private enum State { case idle, running, finished }
    private let source: any WESceneFrameSource
    private let sink: any WESceneFrameSink
    private let limits: WESceneFrameDeliveryLimits
    private var state: State = .idle
    private var stopRequested = false

    public init(source: any WESceneFrameSource, sink: any WESceneFrameSink,
                limits: WESceneFrameDeliveryLimits) {
        self.source = source
        self.sink = sink
        self.limits = limits
    }

    /// Cooperative stop; await the run task to know that source and sink have closed.
    public func requestStop() {
        if state == .running { stopRequested = true }
    }

    public func run() async throws -> WESceneFrameDeliverySummary {
        guard state == .idle else { throw ProbeError.invalid("帧交付会话只能运行一次") }
        state = .running
        var attempts = 0
        var delivered = 0
        var started = ProcessInfo.processInfo.systemUptime
        var reason: WESceneFrameDeliveryStopReason = .durationLimit
        do {
            try Task.checkCancellation()
            try await source.play()
            started = ProcessInfo.processInfo.systemUptime
            while true {
                try Task.checkCancellation()
                if stopRequested { reason = .requested; break }
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                if elapsed >= limits.durationSeconds { reason = .durationLimit; break }
                attempts += 1
                if let frame = try await source.poll(maxDimension: limits.maxDimension) {
                    try validate(frame)
                    if stopRequested { reason = .requested; break }
                    try await sink.accept(frame)
                    delivered += 1
                    if delivered >= limits.maxFrames { reason = .frameLimit; break }
                }
                let remaining = limits.durationSeconds - (ProcessInfo.processInfo.systemUptime - started)
                if remaining > 0 {
                    let delay = min(1 / Double(limits.pollHz), remaining)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            await source.close()
            await sink.finish()
            state = .finished
            return WESceneFrameDeliverySummary(pollAttempts: attempts, deliveredFrames: delivered,
                                               elapsedSeconds: elapsed, stopReason: reason)
        } catch {
            await source.close()
            await sink.finish()
            state = .finished
            throw error
        }
    }

    private func validate(_ frame: WESceneRealtimeSceneFrame) throws {
        let image = frame.preview
        guard image.hasRenderableContent,
              (1...limits.maxDimension).contains(image.width),
              (1...limits.maxDimension).contains(image.height),
              image.rgba.count == image.width * image.height * 4,
              frame.itemSeconds.isFinite, frame.itemSeconds >= 0,
              frame.displaySeconds.isFinite, frame.displaySeconds >= 0 else {
            throw ProbeError.invalid("帧交付收到无效或超限的受限场景帧")
        }
    }
}
