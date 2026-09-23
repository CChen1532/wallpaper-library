import Foundation
import AVFoundation
import CoreVideo
import QuartzCore

public struct WESceneRealtimeVideoFrame: Sendable {
    public let width: Int
    public let height: Int
    public let rgba: Data
    public let itemSeconds: Double
    public let displaySeconds: Double
}

enum ScenePixelBufferDecoder {
    static func rgba(_ buffer: CVPixelBuffer, expectedWidth: Int, expectedHeight: Int) throws -> Data {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
            throw ProbeError.unsupported("实时视频输出不是32位BGRA")
        }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width == expectedWidth, height == expectedHeight else {
            throw ProbeError.unsupported("实时视频帧尺寸与TEX不一致")
        }
        let count = try checkedRGBAByteCount(width: width, height: height)
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw ProbeError.invalid("实时视频像素锁定失败")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw ProbeError.invalid("实时视频像素地址为空") }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard stride >= width * 4, stride <= 64 * 1024 * 1024 else {
            throw ProbeError.invalid("实时视频行跨度非法")
        }
        let input = base.assumingMemoryBound(to: UInt8.self)
        var rgba = [UInt8](repeating: 0, count: count)
        for y in 0..<height {
            for x in 0..<width {
                let source = y * stride + x * 4
                let target = (y * width + x) * 4
                rgba[target] = input[source + 2]
                rgba[target + 1] = input[source + 1]
                rgba[target + 2] = input[source]
                rgba[target + 3] = input[source + 3]
            }
        }
        return Data(rgba)
    }
}

/// Muted, windowless AVPlayer output for a bounded diagnostic. It returns only
/// freshly available video buffers; it does not render a scene or attach to the desktop.
public actor WESceneRealtimeVideoSession {
    private let extracted: SceneVideoTextureSession
    private let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private var closed = false
    public nonisolated let durationSeconds: Double

    private init(extracted: SceneVideoTextureSession, player: AVPlayer,
                 output: AVPlayerItemVideoOutput) {
        self.extracted = extracted
        self.player = player
        self.output = output
        self.durationSeconds = extracted.durationSeconds
    }

    public static func open(packageData: Data, videoTexturePath: String) async throws -> WESceneRealtimeVideoSession {
        let (_, tex) = try WESceneInspection.videoTexture(packageData: packageData, texturePath: videoTexturePath)
        return try await open(tex: tex, path: videoTexturePath)
    }

    static func open(tex: TexFile, path: String) async throws -> WESceneRealtimeVideoSession {
        let extracted = try await SceneVideoTextureSession.open(tex, path: path)
        let item = AVPlayerItem(asset: extracted.asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        output.suppressesPlayerRendering = true
        await item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.volume = 0
        return WESceneRealtimeVideoSession(extracted: extracted, player: player, output: output)
    }

    public func play() throws {
        guard !closed else { throw ProbeError.invalid("视频输出会话已关闭") }
        player.play()
    }

    public func pause() {
        player.pause()
    }

    public func close() {
        if closed { return }
        player.pause()
        player.replaceCurrentItem(with: nil)
        closed = true
    }

    public func poll() throws -> WESceneRealtimeVideoFrame? {
        guard !closed else { throw ProbeError.invalid("视频输出会话已关闭") }
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard itemTime.isValid, !itemTime.isIndefinite,
              output.hasNewPixelBuffer(forItemTime: itemTime) else { return nil }
        var displayTime = CMTime.invalid
        guard let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime) else {
            return nil
        }
        let rgba = try ScenePixelBufferDecoder.rgba(buffer, expectedWidth: extracted.width,
                                                    expectedHeight: extracted.height)
        let itemSeconds = CMTimeGetSeconds(itemTime)
        let actualSeconds = CMTimeGetSeconds(displayTime)
        guard itemSeconds.isFinite, itemSeconds >= 0 else { throw ProbeError.invalid("实时视频项目时间非法") }
        return WESceneRealtimeVideoFrame(width: extracted.width, height: extracted.height, rgba: rgba,
            itemSeconds: itemSeconds,
            displaySeconds: actualSeconds.isFinite && actualSeconds >= 0 ? actualSeconds : itemSeconds)
    }
}
