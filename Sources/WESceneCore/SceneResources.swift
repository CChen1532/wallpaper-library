import Foundation
import CoreFoundation

// 独立实现，只按包内数据与合成夹具解析，不执行脚本或读取包外资源。
struct SceneResourceIssue: Codable, Hashable {
    let code: String
    let owner: String
    let location: String
    let message: String
}

struct SceneResourceEdge: Codable {
    let owner: String // 图层在 scene.json 中的位置，不依赖可重复的 id/name
    let source: String
    let field: String
    let reference: String
    let target: String
    let kind: String
    let status: String // present / missing / unsafe / runtime / invalid
}

struct SceneResourceLayer: Codable {
    let location: String
    let id: String?
    let parent: String?
    let name: String
    let kind: String
    let propertiesJSON: String // 保留变换和 value/user/script 包装；只当数据，不执行
}

struct SceneResourceReport: Codable {
    let schemaVersion: Int
    let packageVersion: String
    let playable: Bool
    let inspectionScope: String
    let layers: [SceneResourceLayer]
    let edges: [SceneResourceEdge]
    let issues: [SceneResourceIssue]
    let missingResources: [String]
}

/// 公共入口只收包数据、返回版本化 JSON；不持有文件路径，不访问外部资源。
public enum WESceneInspection {
    public static func resourceReport(packageData: Data) throws -> Data {
        let report = try SceneResourceInspector(package: parsePkg(packageData)).inspect()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }
}

final class SceneResourceInspector {
    private let package: PkgFile
    private var index: [String: PkgEntry] = [:]
    private var jsonCache: [String: [String: Any]] = [:]
    private var layers: [SceneResourceLayer] = []
    private var edges: [SceneResourceEdge] = []
    private var issues: [SceneResourceIssue] = []
    private var issueSet: Set<SceneResourceIssue> = []
    private var visitedPerOwner: Set<String> = []
    private var inspected = false
    private var steps = 0
    private let maxDepth: Int

    init(package: PkgFile, maxDepth: Int = 32) throws {
        self.package = package
        self.maxDepth = max(1, min(maxDepth, 64))
        var names: Set<String> = []
        for entry in package.entries where !entry.path.isEmpty {
            guard safePackagePath(entry.path), entry.path.count <= 4096 else {
                throw ProbeError.invalid("PKG 存在不安全资源路径")
            }
            let collisionKey = entry.path.precomposedStringWithCanonicalMapping.lowercased()
            guard names.insert(collisionKey).inserted else { throw ProbeError.invalid("PKG 存在重复或大小写歧义资源: \(entry.path)") }
            index[entry.path] = entry
        }
    }

    private func issue(_ code: String, _ owner: String, _ location: String, _ message: String) {
        let item = SceneResourceIssue(code: code, owner: owner, location: location, message: message)
        if issueSet.insert(item).inserted { issues.append(item) }
    }

    private func tick(_ depth: Int) throws {
        steps += 1
        guard steps <= 100_000, edges.count < 30_000, layers.count < 10_000 else { throw ProbeError.invalid("资源报告超过遍历预算") }
        guard depth <= maxDepth else { throw ProbeError.invalid("资源遍历深度超过 \(maxDepth)") }
    }

    private func json(_ path: String) throws -> [String: Any] {
        if let cached = jsonCache[path] { return cached }
        guard let entry = index[path] else { throw ProbeError.invalid("缺失 JSON: \(path)") }
        guard entry.length <= 8 * 1024 * 1024 else { throw ProbeError.invalid("JSON 超过8MiB预算: \(path)") }
        guard let root = try JSONSerialization.jsonObject(with: Data(package.data(of: entry))) as? [String: Any] else {
            throw ProbeError.invalid("JSON 顶层必须为对象: \(path)")
        }
        jsonCache[path] = root
        return root
    }

    private func defaultValue(_ value: Any) -> Any {
        (value as? [String: Any])?["value"] ?? value
    }

    private func scalarID(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let text = value as? String { return text }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        return nil
    }

    private func reference(_ value: Any, kind: String, owner: String, source: String, field: String, stack: [String], depth: Int) throws {
        try tick(depth)
        let raw = defaultValue(value)
        if raw is NSNull { return } // 材质的 null 槽是继承/未绑定，不是文件名
        guard let text = raw as? String, !text.isEmpty else {
            issue("invalidReference", owner, source + ":" + field, "资源引用必须为非空字符串")
            return
        }
        var target = text
        var status = "present"
        if !safePackagePath(text) || text.count > 4096 { status = "unsafe" }
        else if (kind == "texture" && text.hasPrefix("_rt_")) || (kind == "font" && text.hasPrefix("systemfont_")) { status = "runtime" }
        else {
            if kind == "texture" {
                if !target.hasPrefix("materials/") { target = "materials/" + target }
                if !target.hasSuffix(".tex") { target += ".tex" }
            }
            if index[target] == nil { status = "missing" }
        }
        if status == "present" && kind == "texture" {
            do {
                guard let entry = index[target], entry.length <= 128 * 1024 * 1024 else { throw ProbeError.invalid("TEX 超过输入预算") }
                let texture = try parseTex(Data(package.data(of: entry)))
                if texture.isGIF || texture.isVideoTexture || texture.imageFormat == .gif || texture.imageFormat == .mp4 || texture.images.count != 1 {
                    issue("animatedTexture", owner, target, "动画/视频/多图纹理暂不支持")
                }
            } catch {
                status = "invalid"
                issue("invalidTexture", owner, target, String(describing: error))
            }
        }
        edges.append(SceneResourceEdge(owner: owner, source: source, field: field, reference: text, target: target, kind: kind, status: status))
        if status != "present" {
            issue(status + "Resource", owner, source + ":" + field, "\(target)；仅检查包内资源，未推断外部/内置资源可用")
            return
        }
        guard target.hasSuffix(".json") else { return }
        if stack.contains(target) { issue("referenceCycle", owner, target, "资源引用循环"); return }
        let visitKey = owner + "\0" + target
        if !visitedPerOwner.insert(visitKey).inserted { return }
        do {
            let root = try json(target)
            if kind == "model" && root["material"] == nil { issue("missingMaterial", owner, target, "模型没有已识别的 material 字段") }
            if kind == "material" && !(root["passes"] is [Any]) { issue("invalidMaterial", owner, target, "材质缺少 passes 数组") }
            try scan(root, owner: owner, source: target, field: "$", stack: stack + [target], depth: depth + 1)
        } catch {
            issue("invalidJSONOrLimit", owner, target, String(describing: error))
        }
    }

    private func scan(_ value: Any, owner: String, source: String, field: String, stack: [String], depth: Int) throws {
        try tick(depth)
        if let list = value as? [Any] {
            for (i, item) in list.enumerated() { try scan(item, owner: owner, source: source, field: "\(field)[\(i)]", stack: stack, depth: depth + 1) }
            return
        }
        guard let object = value as? [String: Any] else { return }
        for key in object.keys.sorted() {
            guard let item = object[key] else { continue }
            let location = field + "." + key
            if key == "objects" { continue } // 嵌套图层由 walkLayers 处理，避免归属到父层
            if key == "script" {
                issue("script", owner, source + ":" + location, "SceneScript 未执行，默认值不能代表动态结果")
                if let script = item as? String, script.hasPrefix("scripts/"), script.hasSuffix(".js") {
                    try reference(script, kind: "script", owner: owner, source: source, field: location, stack: stack, depth: depth + 1)
                }
                continue
            }
            if key == "user" { issue("userBinding", owner, source + ":" + location, "用户属性未求值，仅保留默认数据") }
            if key == "effects", let list = item as? [Any], !list.isEmpty { issue("effects", owner, source + ":" + location, "效果器暂不支持") }
            let kinds = ["image": "model", "model": "model", "material": "material", "particle": "particle", "font": "font"]
            if let kind = kinds[key] {
                try reference(item, kind: kind, owner: owner, source: source, field: location, stack: stack, depth: depth + 1)
            } else if key == "file", let path = defaultValue(item) as? String, path.hasSuffix(".json") {
                try reference(item, kind: "effect", owner: owner, source: source, field: location, stack: stack, depth: depth + 1)
            } else if key == "textures" {
                if let textures = defaultValue(item) as? [Any] {
                    for (i, texture) in textures.enumerated() {
                        try reference(texture, kind: "texture", owner: owner, source: source, field: "\(location)[\(i)]", stack: stack, depth: depth + 1)
                    }
                } else { issue("invalidTextureSlots", owner, source + ":" + location, "textures 必须为数组") }
            } else if key == "sound" {
                let sounds = defaultValue(item) as? [Any] ?? [defaultValue(item)]
                for (i, sound) in sounds.enumerated() {
                    try reference(sound, kind: "sound", owner: owner, source: source, field: "\(location)[\(i)]", stack: stack, depth: depth + 1)
                }
            } else if key == "shader", let shader = defaultValue(item) as? String {
                issue("shader", owner, source + ":" + location, "着色器尚未实现: \(shader)")
                for ext in [".vert", ".frag"] {
                    let path = shader.hasPrefix("shaders/") ? shader + ext : "shaders/" + shader + ext
                    try reference(path, kind: "shader", owner: owner, source: source, field: location, stack: stack, depth: depth + 1)
                }
            }
            try scan(item, owner: owner, source: source, field: location, stack: stack, depth: depth + 1)
        }
    }

    private func walkLayers(_ items: [Any], parent: String?, base: String, depth: Int) throws {
        try tick(depth)
        for (offset, item) in items.enumerated() {
            let location = "\(base)[\(offset)]"
            guard let object = item as? [String: Any] else { issue("invalidLayer", location, location, "图层不是对象"); continue }
            let candidates = ["image", "model", "text", "particle", "sound", "light", "camera"]
            let nodeKeys: Set<String> = ["id", "name", "origin", "angles", "scale", "parent", "visible", "parallaxDepth", "disablepropagation", "locktransforms", "solid"]
            let kind = candidates.first(where: { object[$0] != nil }) ?? (object["objects"] != nil ? "group" : (object["effects"] != nil || object["shape"] != nil ? "effect" : (Set(object.keys).isSubset(of: nodeKeys) ? "node" : "unknown")))
            let id = scalarID(object["id"])
            let parentID = scalarID(object["parent"]) ?? parent
            if object["parent"] != nil && scalarID(object["parent"]) == nil { issue("invalidParent", location, location, "parent 不是标量ID") }
            if object["objects"] != nil && !(object["objects"] is [Any]) { issue("invalidChildren", location, location, "objects 不是数组") }
            var properties: [String: Any] = [:]
            for key in ["origin", "scale", "angles", "size", "alpha", "visible", "color", "alignment", "parallaxDepth", "disablepropagation", "locktransforms", "solid"] { properties[key] = object[key] }
            let encoded = try JSONSerialization.data(withJSONObject: properties, options: [.sortedKeys])
            layers.append(SceneResourceLayer(location: location, id: id, parent: parentID,
                                             name: object["name"] as? String ?? "", kind: kind,
                                             propertiesJSON: String(decoding: encoded, as: UTF8.self)))
            if !["image", "group", "node"].contains(kind) { issue("unsupportedObject", location, location, "暂不支持 \(kind) 对象") }
            do { try scan(object, owner: location, source: "scene.json", field: location, stack: ["scene.json"], depth: depth + 1) }
            catch { issue("inspectionLimit", location, location, String(describing: error)) }
            if let children = object["objects"] as? [Any] { try walkLayers(children, parent: id, base: location + ".objects", depth: depth + 1) }
        }
    }

    func inspect() throws -> SceneResourceReport {
        guard !inspected else { throw ProbeError.invalid("检查器只能执行一次") }
        inspected = true
        let root = try json("scene.json")
        guard root["camera"] is [String: Any], let general = root["general"] as? [String: Any], let objects = root["objects"] as? [Any] else {
            throw ProbeError.invalid("scene.json 缺少 camera/general/objects 结构")
        }
        issue("rendererUnavailable", "$scene", "scene.json", "资源检查本身不渲染；现有受限预览不具备完整scene效果链及桌面呈现，playable 恒为 false")
        for key in ["bloom", "hdr", "cameraparallax", "camerashake"] where (defaultValue(general[key] ?? false) as? Bool) == true {
            issue("sceneFeature", "$scene", "general." + key, "场景特性暂不支持: \(key)")
        }
        try scan(general, owner: "$scene", source: "scene.json", field: "$.general", stack: ["scene.json"], depth: 0)
        try scan(root["camera"]!, owner: "$scene", source: "scene.json", field: "$.camera", stack: ["scene.json"], depth: 0)
        try walkLayers(objects, parent: nil, base: "$.objects", depth: 0)
        let ids = Dictionary(grouping: layers.compactMap { layer in layer.id.map { ($0, layer) } }, by: { $0.0 })
        for layer in layers {
            if let id = layer.id, (ids[id]?.count ?? 0) > 1 { issue("duplicateLayerID", layer.location, layer.location, "重复图层 id: \(id)") }
            if let parent = layer.parent, ids[parent] == nil { issue("missingParent", layer.location, layer.location, "父图层不存在: \(parent)") }
            var seen: Set<String> = []
            var current = layer
            while let parent = current.parent, let next = ids[parent]?.first?.1 {
                guard seen.insert(parent).inserted else { issue("parentCycle", layer.location, layer.location, "父图层循环"); break }
                current = next
            }
        }
        return SceneResourceReport(schemaVersion: 1, packageVersion: package.magic, playable: false,
                                   inspectionScope: "包内声明引用；不执行脚本、不加载外部 assets、不解码像素、不渲染",
                                   layers: layers, edges: edges, issues: issues,
                                   missingResources: Array(Set(edges.filter { $0.status == "missing" }.map(\.target))).sorted())
    }
}
