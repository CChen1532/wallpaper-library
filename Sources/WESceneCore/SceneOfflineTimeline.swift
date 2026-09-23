import Foundation

/// Deterministic time mapping for a finite offline frame export. It does not pace
/// a display, decode audio, or establish desktop scene playback.
public struct WESceneOfflineTimeline {
    public let framesPerSecond: Double
    public let durationSeconds: Double

    public init(framesPerSecond: Double, durationSeconds: Double) throws {
        guard framesPerSecond.isFinite, (1...60).contains(framesPerSecond) else {
            throw ProbeError.invalid("离线序列帧率必须在1...60且有限")
        }
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw ProbeError.invalid("视频纹理时长必须为正有限秒数")
        }
        self.framesPerSecond = framesPerSecond
        self.durationSeconds = durationSeconds
    }

    public func sourceSeconds(forFrame index: Int) throws -> Double {
        guard (0...120).contains(index) else { throw ProbeError.invalid("离线序列帧号必须在0...120") }
        let elapsed = Double(index) / framesPerSecond
        let source = elapsed.truncatingRemainder(dividingBy: durationSeconds)
        guard source.isFinite, source >= 0, source < durationSeconds else {
            throw ProbeError.invalid("离线序列时间映射失败")
        }
        return source
    }
}
