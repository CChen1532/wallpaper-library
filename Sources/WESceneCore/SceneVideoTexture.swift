import Foundation
import AVFoundation

/// One decoded frame from a video TEX. This is an offline inspection result,
/// not a Wallpaper Engine timeline or a desktop playback capability.
public struct WESceneVideoTextureFrame {
    public let width: Int
    public let height: Int
    public let rgba: Data
    public let durationSeconds: Double
    public let requestedSeconds: Double
    public let actualSeconds: Double
    public let texturePath: String
}

enum SceneVideoTextureDecoder {
    static func payload(_ tex: TexFile) throws -> [UInt8] {
        guard tex.isVideoTexture || tex.imageFormat == .mp4 else {
            throw ProbeError.unsupported("所选 TEX 不是已识别的视频纹理")
        }
        guard tex.images.count == 1, tex.images[0].mipmaps.count == 1 else {
            throw ProbeError.unsupported("视频纹理要求单图单载荷，不能静默选首帧")
        }
        let mipmap = tex.images[0].mipmaps[0]
        let bytes = mipmap.isLZ4
            ? try lz4BlockDecompress(mipmap.rawBytes, expectedSize: mipmap.decompressedSize)
            : mipmap.rawBytes
        guard bytes.count >= 12, bytes.count <= 128 * 1024 * 1024,
              Array(bytes[4..<8]) == Array("ftyp".utf8) else {
            throw ProbeError.invalid("视频纹理缺少包内 MP4 ftyp 头")
        }
        let boxSize = (Int(bytes[0]) << 24) | (Int(bytes[1]) << 16) | (Int(bytes[2]) << 8) | Int(bytes[3])
        guard boxSize >= 12, boxSize <= bytes.count else {
            throw ProbeError.invalid("MP4 ftyp box 超出纹理载荷边界")
        }
        return bytes
    }

    static func frame(_ tex: TexFile, path: String, seconds: Double) async throws -> WESceneVideoTextureFrame {
        guard seconds.isFinite, seconds >= 0 else { throw ProbeError.invalid("请求时间必须是非负有限秒数") }
        let session = try await SceneVideoTextureSession.open(tex, path: path)
        return try await session.frame(atSeconds: seconds)
    }
}

/// Retains one bounded extracted MP4 and one generator across an offline frame sequence.
/// The caller must use it serially; this is not a real-time display decoder.
final class SceneVideoTextureSession {
    private let directory: URL
    let asset: AVURLAsset
    private let generator: AVAssetImageGenerator
    private let texturePath: String
    let width: Int
    let height: Int
    let durationSeconds: Double

    private init(directory: URL, asset: AVURLAsset, generator: AVAssetImageGenerator, path: String,
                 width: Int, height: Int, durationSeconds: Double) {
        self.directory = directory
        self.asset = asset
        self.generator = generator
        self.texturePath = path
        self.width = width
        self.height = height
        self.durationSeconds = durationSeconds
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    static func open(_ tex: TexFile, path: String) async throws -> SceneVideoTextureSession {
        let bytes = try SceneVideoTextureDecoder.payload(tex)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wescene-video-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            let url = directory.appendingPathComponent("embedded.mp4")
            try Data(bytes).write(to: url, options: .withoutOverwriting)
            let asset = AVURLAsset(url: url, options: [
                AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
                AVURLAssetShouldSupportAliasDataReferencesKey: false
            ])
            let duration = try await asset.load(.duration)
            let durationSeconds = CMTimeGetSeconds(duration)
            guard durationSeconds.isFinite, durationSeconds > 0 else {
                throw ProbeError.unsupported("视频纹理时长不可用")
            }
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard tracks.count == 1 else { throw ProbeError.unsupported("只支持单视频轨道 MP4") }
            let size = try await tracks[0].load(.naturalSize)
            guard Int(abs(size.width).rounded()) == tex.imageWidth,
                  Int(abs(size.height).rounded()) == tex.imageHeight else {
                throw ProbeError.unsupported("视频轨道尺寸与 TEX 图像尺寸不一致")
            }
            _ = try checkedRGBAByteCount(width: tex.imageWidth, height: tex.imageHeight)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = false
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            return SceneVideoTextureSession(directory: directory, asset: asset, generator: generator, path: path,
                                            width: tex.imageWidth, height: tex.imageHeight,
                                            durationSeconds: durationSeconds)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func frame(atSeconds seconds: Double) async throws -> WESceneVideoTextureFrame {
        guard seconds.isFinite, seconds >= 0 else { throw ProbeError.invalid("请求时间必须是非负有限秒数") }
        guard seconds < durationSeconds else { throw ProbeError.invalid("请求时间超出视频时长") }
        let (image, actualTime) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        let actualSeconds = CMTimeGetSeconds(actualTime)
        guard actualSeconds.isFinite, actualSeconds >= 0, actualSeconds < durationSeconds else {
            throw ProbeError.invalid("解码器返回无效帧时间")
        }
        let decoded = try cgImageToRGBA(image)
        guard decoded.width == width, decoded.height == height else {
            throw ProbeError.unsupported("解码帧尺寸与 TEX 图像尺寸不一致")
        }
        return WESceneVideoTextureFrame(width: decoded.width, height: decoded.height,
                                        rgba: Data(decoded.rgba), durationSeconds: durationSeconds,
                                        requestedSeconds: seconds, actualSeconds: actualSeconds,
                                        texturePath: texturePath)
    }
}

/// Reuses the validated package and extracted video for a bounded offline sequence.
/// It never schedules the desktop or claims Wallpaper Engine scene playback.
public actor WESceneOfflineFrameSession {
    private let package: PkgFile
    private let video: SceneVideoTextureSession
    public nonisolated let durationSeconds: Double

    private init(package: PkgFile, video: SceneVideoTextureSession) {
        self.package = package
        self.video = video
        self.durationSeconds = video.durationSeconds
    }

    public static func open(packageData: Data, videoTexturePath: String) async throws -> WESceneOfflineFrameSession {
        let (package, tex) = try WESceneInspection.videoTexture(packageData: packageData, texturePath: videoTexturePath)
        return try await WESceneOfflineFrameSession(package: package,
            video: SceneVideoTextureSession.open(tex, path: videoTexturePath))
    }

    public func frame(atSeconds seconds: Double, maxDimension: Int = 1600) async throws -> WESceneStaticPreview {
        guard (1...4096).contains(maxDimension) else { throw ProbeError.invalid("预览最大边长必须在1...4096") }
        let decoded = try await video.frame(atSeconds: seconds)
        return try SceneCompositor(package: package, videoFrame: decoded).render(maxDimension: maxDimension)
    }
}

extension WESceneInspection {
    static func videoTexture(packageData: Data, texturePath: String) throws -> (PkgFile, TexFile) {
        guard packageData.count <= 256 * 1024 * 1024 else { throw ProbeError.invalid("PKG超过256MiB视频检查预算") }
        guard safePackagePath(texturePath), texturePath.hasSuffix(".tex") else {
            throw ProbeError.invalid("视频纹理路径不安全或不是 TEX")
        }
        let package = try parsePkg(packageData)
        _ = try SceneResourceInspector(package: package)
        guard let entry = package.entries.first(where: { $0.path == texturePath }),
              entry.length <= 128 * 1024 * 1024 else {
            throw ProbeError.invalid("包内视频纹理缺失或超过128MiB预算")
        }
        return (package, try parseTex(Data(package.data(of: entry))))
    }

    public static func videoTextureFrame(packageData: Data, texturePath: String,
                                         atSeconds seconds: Double) async throws -> WESceneVideoTextureFrame {
        let (_, tex) = try videoTexture(packageData: packageData, texturePath: texturePath)
        return try await SceneVideoTextureDecoder.frame(tex, path: texturePath, seconds: seconds)
    }
}
