import Foundation
import CoreFoundation

public struct WESceneStaticPreview {
    public let width: Int
    public let height: Int
    public let rgba: Data
    public let diagnosticsJSON: Data
    public let hasRenderableContent: Bool
}

struct PreviewDiagnostic: Codable, Equatable {
    let code: String
    let layer: String
    let detail: String
}

struct PreviewSummary: Codable {
    let schemaVersion: Int
    let width: Int
    let height: Int
    let sceneWidth: Int
    let sceneHeight: Int
    let drawnLayers: [String]
    let skippedLayers: [String]
    let diagnostics: [PreviewDiagnostic]
    let playable: Bool
    let faithful: Bool
    let previewAvailable: Bool
    let description: String
}

struct Point2 { let x: Double; let y: Double }

struct Affine2 {
    let a: Double; let b: Double; let c: Double; let d: Double; let x: Double; let y: Double
    static let identity = Affine2(a: 1, b: 0, c: 0, d: 1, x: 0, y: 0)

    func combined(with rhs: Affine2) -> Affine2 {
        Affine2(a: a * rhs.a + c * rhs.b, b: b * rhs.a + d * rhs.b,
                c: a * rhs.c + c * rhs.d, d: b * rhs.c + d * rhs.d,
                x: a * rhs.x + c * rhs.y + x, y: b * rhs.x + d * rhs.y + y)
    }

    func apply(_ point: Point2) -> Point2 { Point2(x: a * point.x + c * point.y + x, y: b * point.x + d * point.y + y) }

    func inverse() -> Affine2? {
        let determinant = a * d - b * c
        guard determinant.isFinite, abs(determinant) > 0.0000001 else { return nil }
        let ia = d / determinant, ib = -b / determinant, ic = -c / determinant, id = a / determinant
        return Affine2(a: ia, b: ib, c: ic, d: id,
                       x: -(ia * x + ic * y), y: -(ib * x + id * y))
    }

    static func local(origin: Point2, scale: Point2, angle: Double) -> Affine2 {
        let co = cos(angle), si = sin(angle)
        return Affine2(a: co * scale.x, b: si * scale.x, c: -si * scale.y, d: co * scale.y,
                       x: origin.x, y: origin.y)
    }
}

private struct RasterLayer {
    let location: String
    let object: [String: Any]
    let id: String?
    let parent: String?
}

/// Read-only frame zero approximation. Canvas and decoded textures are RGBA in top-down row order.
final class SceneCompositor {
    private let package: PkgFile
    private let entries: [String: PkgEntry]
    private let textureCache = TextureCache()
    private var diagnostics: [PreviewDiagnostic] = []
    private var drawn: [String] = []
    private var skipped: [String] = []
    private var layers: [RasterLayer] = []
    private var byID: [String: Int] = [:]
    private var worlds: [String: Affine2] = [:]
    private var alphas: [String: Double] = [:]
    private var visibility: [String: Bool] = [:]
    private var pixelBudget = 0

    init(package: PkgFile) throws {
        self.package = package
        // Reject ambiguous paths before resolving any references.
        _ = try SceneResourceInspector(package: package)
        entries = Dictionary(uniqueKeysWithValues: package.entries.filter { !$0.path.isEmpty }.map { ($0.path, $0) })
    }

    private func note(_ code: String, _ layer: String, _ detail: String) {
        let item = PreviewDiagnostic(code: code, layer: layer, detail: detail)
        if !diagnostics.contains(item) { diagnostics.append(item) }
    }

    private func data(_ path: String, max: Int = 128 * 1024 * 1024) throws -> Data {
        guard safePackagePath(path), let entry = entries[path], entry.length <= max else {
            throw ProbeError.invalid("包内资源缺失、不安全或超过预算: \(path)")
        }
        return Data(try package.data(of: entry))
    }

    private func json(_ path: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data(path, max: 8 * 1024 * 1024)) as? [String: Any] else {
            throw ProbeError.invalid("JSON 根必须是对象: \(path)")
        }
        return object
    }

    private func unwrapped(_ value: Any?, layer: String, field: String) -> Any? {
        guard let value else { return nil }
        if let dictionary = value as? [String: Any] {
            if dictionary["script"] != nil { note("scriptDefault", layer, "\(field) 使用静态默认值") }
            if dictionary["user"] != nil { note("userDefault", layer, "\(field) 使用静态默认值") }
            return dictionary["value"]
        }
        return value
    }

    private func number(_ value: Any?, fallback: Double, layer: String, field: String) throws -> Double {
        guard let raw = unwrapped(value, layer: layer, field: field) else { return fallback }
        let result: Double?
        if let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { result = n.doubleValue }
        else if let s = raw as? String { result = Double(s) }
        else { result = nil }
        guard let result, result.isFinite else { throw ProbeError.invalid("\(field) 不是有限数字") }
        return result
    }

    private func vector(_ value: Any?, fallback: Point2, layer: String, field: String) throws -> Point2 {
        guard let raw = unwrapped(value, layer: layer, field: field) else { return fallback }
        let parts: [Any]
        if let s = raw as? String { parts = s.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
        else if let a = raw as? [Any] { parts = a }
        else { throw ProbeError.invalid("\(field) 不是向量") }
        guard parts.count >= 2 else { throw ProbeError.invalid("\(field) 缺少坐标") }
        return Point2(x: try number(parts[0], fallback: fallback.x, layer: layer, field: field),
                      y: try number(parts[1], fallback: fallback.y, layer: layer, field: field))
    }

    private func visible(_ value: Any?, layer: String) throws -> Bool {
        guard let raw = unwrapped(value, layer: layer, field: "visible") else { return true }
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw ProbeError.invalid("visible 不是布尔值")
        }
        return number.boolValue
    }

    private func flatten(_ objects: [Any], prefix: String, inherited: String?, depth: Int = 0) throws {
        guard depth <= 32, layers.count + objects.count <= 10_000 else { throw ProbeError.invalid("图层超过深度32或10000个") }
        for (index, item) in objects.enumerated() {
            let location = "\(prefix)[\(index)]"
            guard let object = item as? [String: Any] else { note("invalidLayer", location, "图层不是对象"); continue }
            let id = (object["id"] as? NSNumber)?.stringValue ?? object["id"] as? String
            let parent = (object["parent"] as? NSNumber)?.stringValue ?? object["parent"] as? String ?? inherited
            if let id {
                if byID[id] != nil { throw ProbeError.invalid("重复图层ID: \(id)") }
                byID[id] = layers.count
            }
            layers.append(RasterLayer(location: location, object: object, id: id, parent: parent))
            if let children = object["objects"] as? [Any] { try flatten(children, prefix: location + ".objects", inherited: id, depth: depth + 1) }
        }
    }

    private func world(_ index: Int, stack: Set<Int> = []) throws -> (Affine2, Double, Bool) {
        let layer = layers[index]
        if let cached = worlds[layer.location] {
            return (cached, alphas[layer.location]!, visibility[layer.location]!)
        }
        guard stack.count < 32, !stack.contains(index) else { throw ProbeError.invalid("父级循环或深度超过32") }
        let object = layer.object
        let origin = try vector(object["origin"], fallback: Point2(x: 0, y: 0), layer: layer.location, field: "origin")
        let scale = try vector(object["scale"], fallback: Point2(x: 1, y: 1), layer: layer.location, field: "scale")
        let angle: Double
        if let raw = unwrapped(object["angles"], layer: layer.location, field: "angles") {
            let values: [String]
            if let string = raw as? String { values = string.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
            else if let array = raw as? [NSNumber] { values = array.map(\.stringValue) }
            else { throw ProbeError.invalid("angles 格式未知") }
            guard values.count >= 3, let ax = Double(values[0]), let ay = Double(values[1]), let z = Double(values[2]),
                  ax.isFinite, ay.isFinite, z.isFinite else { throw ProbeError.invalid("angles 缺少有限角度") }
            if ax != 0 || ay != 0 {
                note("projected3D", layer.location, "X/Y旋转未实现，仅使用Z角")
            }
            angle = z
        } else { angle = 0 }
        let own = Affine2.local(origin: origin, scale: scale, angle: angle)
        let ownAlpha = try number(object["alpha"], fallback: 1, layer: layer.location, field: "alpha")
        guard (0...1).contains(ownAlpha) else { throw ProbeError.invalid("alpha 超出0...1") }
        let ownVisible = try visible(object["visible"], layer: layer.location)
        var result = own, alpha = ownAlpha, show = ownVisible
        if let parent = layer.parent {
            guard let parentIndex = byID[parent] else { throw ProbeError.invalid("父级不存在: \(parent)") }
            let upstream = try world(parentIndex, stack: stack.union([index]))
            result = upstream.0.combined(with: own)
            alpha *= upstream.1
            show = show && upstream.2
        }
        guard result.a.isFinite, result.b.isFinite, result.c.isFinite, result.d.isFinite,
              result.x.isFinite, result.y.isFinite else { throw ProbeError.invalid("变换结果非法") }
        worlds[layer.location] = result; alphas[layer.location] = alpha; visibility[layer.location] = show
        return (result, alpha, show)
    }

    private func texture(for layer: RasterLayer) throws -> (DecodedTexture, Point2) {
        let object = layer.object
        guard let modelPath = unwrapped(object["image"], layer: layer.location, field: "image") as? String,
              modelPath.hasSuffix(".json") else { throw ProbeError.unsupported("只支持包内JSON模型") }
        let model = try json(modelPath)
        guard let materialPath = model["material"] as? String else { throw ProbeError.invalid("模型缺少材质") }
        let material = try json(materialPath)
        guard let passes = material["passes"] as? [[String: Any]], passes.count == 1,
              let textureSlots = passes[0]["textures"] as? [Any] else {
            throw ProbeError.unsupported("仅支持单pass、明确纹理槽的材质")
        }
        let paths = textureSlots.compactMap { $0 as? String }
        guard paths.count == 1, let source = paths.first else { throw ProbeError.unsupported("仅支持一个静态颜色纹理") }
        let blend = passes[0]["blending"] as? String ?? "translucent"
        guard blend == "translucent" || blend == "normal" else { throw ProbeError.unsupported("材质混合模式: \(blend)") }
        if let shader = passes[0]["shader"] as? String {
            guard shader == "genericimage4" || shader == "genericimage2" else { throw ProbeError.unsupported("自定义着色器: \(shader)") }
            note("shaderApproximation", layer.location, "\(shader) 采用基础贴图近似")
        }
        let path = source.hasPrefix("materials/") ? source : "materials/" + source
        let texPath = path.hasSuffix(".tex") ? path : path + ".tex"
        let tex = try textureCache.load(data(texPath))
        guard tex.sourceFormat != .r8 && tex.sourceFormat != .rg88 else { throw ProbeError.unsupported("灰度/双通道纹理不能直接作为颜色图") }
        let defaultSize = Point2(x: Double(model["width"] as? Int ?? tex.imageWidth),
                                 y: Double(model["height"] as? Int ?? tex.imageHeight))
        let size = try vector(object["size"], fallback: defaultSize, layer: layer.location, field: "size")
        guard size.x > 0, size.y > 0, size.x < 100_000, size.y < 100_000 else { throw ProbeError.invalid("图层size非法") }
        return (tex, size)
    }

    private func draw(texture: DecodedTexture, size: Point2, matrix: Affine2, alpha: Double,
                      canvas: inout [UInt8], width: Int, height: Int, sceneWidth: Double, sceneHeight: Double) throws {
        guard alpha > 0 else { return }
        guard let inverse = matrix.inverse() else { throw ProbeError.invalid("图层变换不可逆（零缩放）") }
        let corners = [Point2(x: -size.x/2, y: -size.y/2), Point2(x: size.x/2, y: -size.y/2),
                       Point2(x: -size.x/2, y: size.y/2), Point2(x: size.x/2, y: size.y/2)].map(matrix.apply)
        let minX = corners.map(\.x).min()!, maxX = corners.map(\.x).max()!
        let minY = corners.map(\.y).min()!, maxY = corners.map(\.y).max()!
        guard [minX,maxX,minY,maxY].allSatisfy(\.isFinite) else { throw ProbeError.invalid("图层边界非法") }
        guard maxX > 0, minX < sceneWidth, maxY > 0, minY < sceneHeight else { return }
        let left = Int(floor(max(0, minX) / sceneWidth * Double(width)))
        let right = Int(ceil(min(sceneWidth, maxX) / sceneWidth * Double(width)))
        let top = Int(floor((sceneHeight - min(sceneHeight, maxY)) / sceneHeight * Double(height)))
        let bottom = Int(ceil((sceneHeight - max(0, minY)) / sceneHeight * Double(height)))
        guard left < right, top < bottom else { return }
        pixelBudget += (right-left) * (bottom-top)
        guard pixelBudget <= 100_000_000 else { throw ProbeError.invalid("合成超过1亿采样预算") }
        let cropWidth = min(texture.width, texture.imageWidth)
        let cropHeight = min(texture.height, texture.imageHeight)
        guard cropWidth > 0, cropHeight > 0 else { throw ProbeError.invalid("纹理裁剪尺寸非法") }
        for y in top..<bottom {
            for x in left..<right {
                let world = Point2(x: (Double(x)+0.5)/Double(width)*sceneWidth,
                                   y: sceneHeight-(Double(y)+0.5)/Double(height)*sceneHeight)
                let local = inverse.apply(world)
                let u = local.x / size.x + 0.5
                let v = 0.5 - local.y / size.y
                guard u >= 0, u < 1, v >= 0, v < 1 else { continue }
                let sourceX = min(cropWidth-1, Int(u * Double(cropWidth)))
                let sourceY = min(cropHeight-1, Int(v * Double(cropHeight)))
                let source = (sourceY * texture.width + sourceX) * 4
                let destination = (y * width + x) * 4
                let sourceAlpha = Double(texture.rgba[source+3]) / 255 * alpha
                if sourceAlpha <= 0 { continue }
                let destinationAlpha = Double(canvas[destination+3]) / 255
                let outAlpha = sourceAlpha + destinationAlpha * (1-sourceAlpha)
                for channel in 0..<3 {
                    let color = (Double(texture.rgba[source+channel])*sourceAlpha +
                                 Double(canvas[destination+channel])*destinationAlpha*(1-sourceAlpha)) / outAlpha
                    canvas[destination+channel] = UInt8(min(255, max(0, Int(color.rounded()))))
                }
                canvas[destination+3] = UInt8(min(255, max(0, Int((outAlpha*255).rounded()))))
            }
        }
    }

    func render(maxDimension: Int = 1600) throws -> WESceneStaticPreview {
        guard (1...4096).contains(maxDimension) else { throw ProbeError.invalid("预览最大边长必须在1...4096") }
        let root = try json("scene.json")
        guard let general = root["general"] as? [String: Any],
              let projection = general["orthogonalprojection"] as? [String: Any],
              let sceneWidth = projection["width"] as? Int,
              let sceneHeight = projection["height"] as? Int,
              let objects = root["objects"] as? [Any],
              sceneWidth > 0, sceneHeight > 0, sceneWidth <= 16384, sceneHeight <= 16384 else {
            throw ProbeError.invalid("缺少有效 orthogonalprojection/objects")
        }
        let ratio = min(1.0, Double(maxDimension)/Double(max(sceneWidth, sceneHeight)))
        let width = max(1, Int((Double(sceneWidth)*ratio).rounded()))
        let height = max(1, Int((Double(sceneHeight)*ratio).rounded()))
        _ = try checkedRGBAByteCount(width: width, height: height)
        var canvas = [UInt8](repeating: 0, count: width*height*4)
        let clearEnabled = (general["clearenabled"] as? Bool) ?? false
        if clearEnabled, let color = general["clearcolor"] {
            let rgb = try vector(color, fallback: Point2(x: 0, y: 0), layer: "$scene", field: "clearcolor")
            let parts = (color as? String)?.split(whereSeparator: { $0.isWhitespace }) ?? []
            let blue = parts.count >= 3 ? (Double(parts[2]) ?? 0) : 0
            let values = [rgb.x, rgb.y, blue]
            guard values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw ProbeError.invalid("clearcolor非法") }
            let fill = values.map { UInt8(($0*255).rounded()) } + [255]
            for i in stride(from: 0, to: canvas.count, by: 4) { canvas[i]=fill[0]; canvas[i+1]=fill[1]; canvas[i+2]=fill[2]; canvas[i+3]=255 }
        }
        try flatten(objects, prefix: "$.objects", inherited: nil)
        for index in layers.indices {
            let layer = layers[index]
            guard layer.object["image"] != nil else {
                if layer.object["particle"] != nil || layer.object["text"] != nil || layer.object["effects"] != nil || layer.object["sound"] != nil {
                    note("unsupportedLayer", layer.location, "该对象类型未静态合成")
                }
                continue
            }
            do {
                if let effects = layer.object["effects"] as? [Any], !effects.isEmpty { note("effectsOmitted", layer.location, "效果器未渲染，仅显示基础图") }
                let blendMode = layer.object["colorBlendMode"] as? Int ?? 0
                guard blendMode == 0 else { throw ProbeError.unsupported("图层混合模式 \(blendMode)") }
                let (transform, alpha, show) = try world(index)
                guard show, alpha > 0 else { continue }
                let (image, size) = try texture(for: layer)
                try draw(texture: image, size: size, matrix: transform, alpha: alpha, canvas: &canvas,
                         width: width, height: height, sceneWidth: Double(sceneWidth), sceneHeight: Double(sceneHeight))
                drawn.append(layer.location)
            } catch {
                skipped.append(layer.location)
                note("layerSkipped", layer.location, String(describing: error))
            }
        }
        let summary = PreviewSummary(schemaVersion: 1, width: width, height: height, sceneWidth: sceneWidth,
                                     sceneHeight: sceneHeight, drawnLayers: drawn, skippedLayers: skipped,
                                     diagnostics: diagnostics, playable: false, faithful: false,
                                     previewAvailable: !drawn.isEmpty,
                                     description: "静态frame 0近似画面；不支持动画、脚本、效果器、粒子与桌面播放")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return WESceneStaticPreview(width: width, height: height, rgba: Data(canvas),
                                    diagnosticsJSON: try encoder.encode(summary),
                                    hasRenderableContent: summary.previewAvailable)
    }
}

extension WESceneInspection {
    public static func staticPreview(packageData: Data, maxDimension: Int = 1600) throws -> WESceneStaticPreview {
        guard packageData.count <= 256 * 1024 * 1024 else { throw ProbeError.invalid("PKG超过256MiB预览预算") }
        return try SceneCompositor(package: parsePkg(packageData)).render(maxDimension: maxDimension)
    }
}
