import Foundation
import Metal

/// Independent GPU implementation of the existing restricted 2D scene subset.
/// It owns no window and never changes the desktop. No Mirage source is copied.
final class SceneMetalCompositor {
    private struct LayerParameters {
        var inverseX: SIMD4<Float>
        var inverseY: SIMD4<Float>
        var sizeAlpha: SIMD4<Float>
        var keyColor: SIMD4<Float>
        var keyOptions: SIMD4<Float>
    }

    private let plan: ScenePreparedFramePlan
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let clearPipeline: MTLComputePipelineState
    private let layerPipeline: MTLComputePipelineState
    private let output: MTLTexture
    private let videoTexture: MTLTexture
    private let staticTextures: [MTLTexture?]

    static func available() -> Bool { MTLCreateSystemDefaultDevice() != nil }

    init(plan: ScenePreparedFramePlan) throws {
        guard plan.layers.count <= 64,
              plan.width * plan.height * max(1, plan.layers.count) <= 100_000_000 else {
            throw ProbeError.unsupported("Scene Metal 图层或采样预算超限")
        }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw ProbeError.unsupported("Metal GPU 不可用")
        }
        self.plan = plan
        self.device = device
        self.queue = queue
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        guard let clearFunction = library.makeFunction(name: "clearScene"),
              let layerFunction = library.makeFunction(name: "drawSceneLayer") else {
            throw ProbeError.unsupported("Scene Metal 着色器函数缺失")
        }
        clearPipeline = try device.makeComputePipelineState(function: clearFunction)
        layerPipeline = try device.makeComputePipelineState(function: layerFunction)
        guard let output = Self.makeTexture(device: device, width: plan.width, height: plan.height,
                                            usage: [.shaderRead, .shaderWrite]),
              let dynamic = plan.layers.first(where: { $0.texture == nil }),
              let videoTexture = Self.makeTexture(device: device, width: dynamic.textureWidth,
                                                   height: dynamic.textureHeight, usage: [.shaderRead]) else {
            throw ProbeError.unsupported("Scene Metal 输出或视频纹理创建失败")
        }
        self.output = output
        self.videoTexture = videoTexture
        var textures: [MTLTexture?] = []
        for layer in plan.layers {
            guard let source = layer.texture else { textures.append(nil); continue }
            guard let texture = Self.makeTexture(device: device, width: source.width,
                                                 height: source.height, usage: [.shaderRead]),
                  source.rgba.count == source.width * source.height * 4 else {
                throw ProbeError.unsupported("Scene Metal 静态纹理创建失败")
            }
            source.rgba.withUnsafeBytes { bytes in
                texture.replace(region: MTLRegionMake2D(0, 0, source.width, source.height),
                                mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: source.width * 4)
            }
            textures.append(texture)
        }
        staticTextures = textures
    }

    private static func makeTexture(device: MTLDevice, width: Int, height: Int,
                                    usage: MTLTextureUsage) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                   width: width, height: height,
                                                                   mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = usage
        return device.makeTexture(descriptor: descriptor)
    }

    func render(videoRGBA: Data, itemSeconds: Double, displaySeconds: Double,
                durationSeconds: Double, texturePath: String) throws -> WESceneStaticPreview {
        guard videoRGBA.count == videoTexture.width * videoTexture.height * 4 else {
            throw ProbeError.invalid("Scene Metal 视频帧尺寸不匹配")
        }
        videoRGBA.withUnsafeBytes { bytes in
            videoTexture.replace(region: MTLRegionMake2D(0, 0, videoTexture.width, videoTexture.height),
                                 mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: videoTexture.width * 4)
        }
        guard let command = queue.makeCommandBuffer(), let clear = command.makeComputeCommandEncoder() else {
            throw ProbeError.unsupported("Scene Metal 命令缓冲区创建失败")
        }
        var clearColor = SIMD4<Float>(plan.clearRGBA.map { Float($0) / 255 })
        clear.setComputePipelineState(clearPipeline)
        clear.setTexture(output, index: 0)
        clear.setBytes(&clearColor, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        dispatch(clear, pipeline: clearPipeline)
        clear.endEncoding()

        for (index, layer) in plan.layers.enumerated() {
            guard let encoder = command.makeComputeCommandEncoder() else {
                throw ProbeError.unsupported("Scene Metal 图层编码器创建失败")
            }
            let key = layer.colorKey
            var parameters = LayerParameters(
                inverseX: SIMD4(Float(layer.inverse.a), Float(layer.inverse.c),
                                Float(layer.inverse.x), Float(plan.sceneWidth)),
                inverseY: SIMD4(Float(layer.inverse.b), Float(layer.inverse.d),
                                Float(layer.inverse.y), Float(plan.sceneHeight)),
                sizeAlpha: SIMD4(Float(layer.size.x), Float(layer.size.y),
                                 Float(layer.alpha), key == nil ? 0 : 1),
                keyColor: SIMD4(Float(key?.red ?? 0), Float(key?.green ?? 0),
                                Float(key?.blue ?? 0), Float(key?.alpha ?? 1)),
                keyOptions: SIMD4(Float(key?.fuzziness ?? 0), Float(key?.tolerance ?? 0),
                                  Float(layer.cropWidth), Float(layer.cropHeight)))
            encoder.setComputePipelineState(layerPipeline)
            encoder.setTexture(output, index: 0)
            encoder.setTexture(staticTextures[index] ?? videoTexture, index: 1)
            encoder.setBytes(&parameters, length: MemoryLayout<LayerParameters>.stride, index: 0)
            dispatch(encoder, pipeline: layerPipeline)
            encoder.endEncoding()
        }
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw command.error ?? ProbeError.unsupported("Scene Metal 合成失败")
        }
        var pixels = Data(count: plan.width * plan.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            output.getBytes(bytes.baseAddress!, bytesPerRow: plan.width * 4,
                            from: MTLRegionMake2D(0, 0, plan.width, plan.height), mipmapLevel: 0)
        }
        let summary = PreviewSummary(schemaVersion: 1, width: plan.width, height: plan.height,
            sceneWidth: plan.sceneWidth, sceneHeight: plan.sceneHeight,
            drawnLayers: plan.drawn, skippedLayers: plan.skipped,
            diagnostics: plan.diagnostics, playable: false, faithful: false,
            previewAvailable: !plan.drawn.isEmpty, frameMode: "windowlessRealtimeProbeMetal",
            videoTexture: texturePath, requestedSeconds: itemSeconds,
            actualSeconds: displaySeconds, videoDurationSeconds: durationSeconds,
            description: "Metal 加速的无窗口受限基础图合成；非完整 scene 渲染或正式桌面播放")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return WESceneStaticPreview(width: plan.width, height: plan.height, rgba: pixels,
                                    diagnosticsJSON: try encoder.encode(summary),
                                    hasRenderableContent: !plan.drawn.isEmpty)
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState) {
        let group = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreads(MTLSize(width: plan.width, height: plan.height, depth: 1),
                                threadsPerThreadgroup: group)
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Params {
        float4 inverseX;
        float4 inverseY;
        float4 sizeAlpha;
        float4 keyColor;
        float4 keyOptions;
    };
    kernel void clearScene(texture2d<float, access::write> target [[texture(0)]],
                           constant float4& color [[buffer(0)]],
                           uint2 p [[thread_position_in_grid]]) {
        if (p.x < target.get_width() && p.y < target.get_height()) target.write(color, p);
    }
    kernel void drawSceneLayer(texture2d<float, access::read_write> target [[texture(0)]],
                               texture2d<float, access::read> source [[texture(1)]],
                               constant Params& q [[buffer(0)]],
                               uint2 p [[thread_position_in_grid]]) {
        if (p.x >= target.get_width() || p.y >= target.get_height()) return;
        float wx = (float(p.x) + 0.5f) / float(target.get_width()) * q.inverseX.w;
        float wy = q.inverseY.w - (float(p.y) + 0.5f) / float(target.get_height()) * q.inverseY.w;
        float lx = q.inverseX.x * wx + q.inverseX.y * wy + q.inverseX.z;
        float ly = q.inverseY.x * wx + q.inverseY.y * wy + q.inverseY.z;
        float u = lx / q.sizeAlpha.x + 0.5f;
        float v = 0.5f - ly / q.sizeAlpha.y;
        if (u < 0.0f || u >= 1.0f || v < 0.0f || v >= 1.0f) return;
        uint sx = min(uint(q.keyOptions.z) - 1u, uint(u * q.keyOptions.z));
        uint sy = min(uint(q.keyOptions.w) - 1u, uint(v * q.keyOptions.w));
        float4 src = source.read(uint2(sx, sy));
        float keyOpacity = 1.0f;
        if (q.sizeAlpha.w > 0.5f) {
            float delta = abs(q.keyColor.x - src.r) + abs(q.keyColor.y - src.g)
                        + abs(q.keyColor.z - src.b);
            float lower = 0.001f;
            float upper = 0.002f + q.keyOptions.x;
            float t = clamp((delta - q.keyOptions.y - lower) / (upper - lower), 0.0f, 1.0f);
            float blend = t * t * (3.0f - 2.0f * t);
            keyOpacity = q.keyColor.w * (1.0f - blend) + blend;
        }
        float sourceAlpha = src.a * q.sizeAlpha.z * keyOpacity;
        if (sourceAlpha <= 0.0f) return;
        float4 dst = target.read(p);
        float outAlpha = sourceAlpha + dst.a * (1.0f - sourceAlpha);
        float3 outColor = (src.rgb * sourceAlpha + dst.rgb * dst.a * (1.0f - sourceAlpha)) / outAlpha;
        target.write(float4(outColor, outAlpha), p);
    }
    """
}
