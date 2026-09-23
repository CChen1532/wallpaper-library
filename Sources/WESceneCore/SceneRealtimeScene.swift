import Foundation

public struct WESceneRealtimeSceneFrame: Sendable {
    public let preview: WESceneStaticPreview
    public let itemSeconds: Double
    public let displaySeconds: Double
}

/// Joins freshly decoded video pixels with the existing restricted scene compositor.
/// No window, display timer, audio, or desktop backend is created here.
public actor WESceneRealtimeSceneSession {
    private let package: PkgFile
    private let texturePath: String
    private let video: WESceneRealtimeVideoSession

    private init(package: PkgFile, texturePath: String, video: WESceneRealtimeVideoSession) {
        self.package = package
        self.texturePath = texturePath
        self.video = video
    }

    public static func open(packageData: Data, videoTexturePath: String) async throws -> WESceneRealtimeSceneSession {
        let (package, tex) = try WESceneInspection.videoTexture(packageData: packageData, texturePath: videoTexturePath)
        let video = try await WESceneRealtimeVideoSession.open(tex: tex, path: videoTexturePath)
        return WESceneRealtimeSceneSession(package: package, texturePath: videoTexturePath, video: video)
    }

    public func play() async throws { try await video.play() }
    public func pause() async { await video.pause() }
    public func close() async { await video.close() }

    public func poll(maxDimension: Int = 960) async throws -> WESceneRealtimeSceneFrame? {
        guard (1...1600).contains(maxDimension) else { throw ProbeError.invalid("无窗口合成最大边长必须在1...1600") }
        guard let frame = try await video.poll() else { return nil }
        let injected = WESceneVideoTextureFrame(width: frame.width, height: frame.height,
            rgba: frame.rgba, durationSeconds: video.durationSeconds,
            requestedSeconds: frame.itemSeconds, actualSeconds: frame.displaySeconds,
            texturePath: texturePath)
        let preview = try SceneCompositor(package: package, videoFrame: injected,
                                           videoFrameKind: .windowlessProbe).render(maxDimension: maxDimension)
        return WESceneRealtimeSceneFrame(preview: preview, itemSeconds: frame.itemSeconds,
                                          displaySeconds: frame.displaySeconds)
    }
}
