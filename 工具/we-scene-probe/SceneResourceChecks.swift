import Foundation

func runResourceChecks(_ c: inout Checker) throws {
    func scene(_ objects: [[String: Any]]) -> [String: Any] { ["camera": [:], "general": [:], "objects": objects] }
    let model: [String: Any] = ["material": "materials/a.json"]
    let material: [String: Any] = ["passes": [["textures": ["a"]]]]
    let texture = try makeSyntheticDXT1Tex()
    func package(_ root: [String: Any], extra: [String: Any] = [:], duplicate: Bool = false) throws -> PkgFile {
        var documents: [String: Any] = ["scene.json": root, "models/a.json": model, "materials/a.json": material, "materials/a.tex": texture]
        documents.merge(extra) { _, newer in newer }
        var files = try documents.keys.sorted().map { path -> (String, Data) in
            let value = documents[path]!
            return (path, try (value as? Data) ?? JSONSerialization.data(withJSONObject: value))
        }
        if duplicate { files.append(files[0]) }
        var bytes = sizedStringBytes("PKGV0024") + u32le(files.count)
        var offset = 0
        for (path, data) in files { bytes += sizedStringBytes(path) + u32le(offset) + u32le(data.count); offset += data.count }
        for (_, data) in files { bytes += data }
        return try parsePkg(Data(bytes))
    }
    func report(_ objects: [[String: Any]], extra: [String: Any] = [:], depth: Int = 32) throws -> SceneResourceReport {
        try SceneResourceInspector(package: package(scene(objects), extra: extra), maxDepth: depth).inspect()
    }
    func rejects(_ operation: () throws -> Void) -> Bool { do { try operation(); return false } catch { return true } }
    let layer: [String: Any] = ["id": 1, "name": "图层", "image": "models/a.json", "origin": "1 2 3"]
    let good = try report([layer])
    c.check(good.edges.map(\.target) == ["models/a.json", "materials/a.json", "materials/a.tex"], "图层→模型→材质→纹理引用链")
    c.check(good.edges.allSatisfy { $0.status == "present" } && !good.playable, "资源齐全仍不声称可播放")
    c.check(good.layers.first?.propertiesJSON.contains("1 2 3") == true, "保留变换数据")
    let shared = try report([layer, ["id": 2, "image": "models/a.json"]])
    c.check(shared.edges.count == 6 && Set(shared.edges.map(\.owner)).count == 2, "共享资源保留各图层引用归属")
    let missing = try report([["image": "models/util/solidlayer.json"]])
    c.check(missing.missingResources == ["models/util/solidlayer.json"], "缺失util模型不假装内置可用")
    let unsafe = try report([["image": "../outside.json"], ["image": "/absolute.json"]])
    c.check(unsafe.edges.allSatisfy { $0.status == "unsafe" }, "拒绝相对穿越及绝对引用")
    let bad = try report([layer, ["image": "models/bad.json"]], extra: ["models/bad.json": Data("{".utf8)])
    c.check(bad.issues.contains { $0.code == "invalidJSONOrLimit" } && bad.edges.contains { $0.target == "materials/a.tex" }, "坏JSON不妨碍另一有效链")
    let cycle = try report([layer], extra: ["materials/a.json": ["material": "models/a.json"]])
    c.check(cycle.issues.contains { $0.code == "referenceCycle" }, "资源循环有界终止")
    c.check(rejects { _ = try SceneResourceInspector(package: package(scene([layer]), duplicate: true)) }, "重复包条目拒绝")
    let limited = try report([layer], depth: 2)
    c.check(limited.issues.contains { $0.code == "invalidJSONOrLimit" || $0.code == "inspectionLimit" }, "递归超限明确报告")
    let dynamic = try report([["image": ["value": "models/a.json", "user": "show"], "alpha": ["value": 1, "script": "return 1"], "effects": [["file": "effects/missing.json"]]]])
    c.check(dynamic.issues.contains { $0.code == "script" } && dynamic.issues.contains { $0.code == "userBinding" } && dynamic.issues.contains { $0.code == "effects" }, "脚本/用户绑定/效果器不静默降级")
    c.check(dynamic.edges.contains { $0.target == "materials/a.tex" }, "多态value保留默认引用")
    let slots = try report([layer], extra: ["materials/a.json": ["passes": [["textures": [NSNull(), "_rt_FullFrameBuffer", "materials/a.tex"]]]]])
    c.check(slots.edges.contains { $0.status == "runtime" } && !slots.edges.contains { $0.reference == "null" }, "null槽与运行时纹理正确分类")
    c.check(slots.edges.contains { $0.target == "materials/a.tex" && $0.status == "present" }, "完整纹理路径不重复前缀后缀")
    let parents = try report([["id": 1, "parent": 2], ["id": 2, "parent": 1], ["id": 3, "parent": 999]])
    c.check(parents.issues.contains { $0.code == "parentCycle" } && parents.issues.contains { $0.code == "missingParent" }, "父图层循环及缺失父级识别")
    let nested = try report([["id": 7, "objects": [layer]]])
    c.check(nested.layers.count == 2 && nested.layers[1].parent == "7" && Set(nested.edges.map(\.owner)) == ["$.objects[0].objects[0]"], "嵌套图层继承父级且资源不归到父层")
    let duplicateIDs = try report([layer, layer])
    c.check(duplicateIDs.issues.contains { $0.code == "duplicateLayerID" }, "重复图层ID报告")
    var animated = texture
    animated.replaceSubrange(22..<26, with: [4,0,0,0])
    let animation = try report([layer], extra: ["materials/a.tex": animated])
    c.check(animation.issues.contains { $0.code == "animatedTexture" }, "图层引用动画纹理明确受限")
    let malformed = try report([layer], extra: ["materials/a.tex": Data([0,1,2])])
    c.check(malformed.edges.contains { $0.kind == "texture" && $0.status == "invalid" }, "损坏纹理头识别")
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    c.check(try encoder.encode(good) == encoder.encode(report([layer])), "报告JSON可复现")
    c.check(rejects { _ = try SceneResourceInspector(package: package(["objects": []])).inspect() }, "缺失场景根结构拒绝")
    let unknown = try report([["text": "hello"], ["particle": "particles/x.json"]])
    c.check(unknown.issues.filter { $0.code == "unsupportedObject" }.count == 2, "文本/粒子明确未实现")
    c.check(rejects { _ = try SceneResourceInspector(package: package(scene([]), extra: ["../escape": Data()])) }, "包索引拒绝不安全条目")
    let systemFont = try report([["text": "a", "font": "systemfont_arial"]])
    c.check(systemFont.edges.first?.status == "runtime" && systemFont.missingResources.isEmpty, "系统字体令牌不误报为包内缺失文件")
    let badSlots = try report([layer], extra: ["materials/a.json": ["passes": [["textures": "a"]]]])
    c.check(badSlots.issues.contains { $0.code == "invalidTextureSlots" }, "畸形纹理槽结构明确报告")
    let noMaterial = try report([layer], extra: ["models/a.json": ["width": 100]])
    c.check(noMaterial.issues.contains { $0.code == "missingMaterial" }, "模型缺失材质明确报告")
    let materialMissing = try report([layer], extra: ["models/a.json": ["material": "materials/missing.json"]])
    c.check(materialMissing.missingResources == ["materials/missing.json"], "材质缺失停止该链")
    let nestedScript = try report([layer], extra: ["materials/a.json": ["passes": [["textures": ["a"], "alpha": ["script": "return 0", "value": 0]]]]])
    c.check(nestedScript.issues.contains { $0.code == "script" && $0.location.hasPrefix("materials/a.json") }, "材质内脚本有来源定位")
    let jsonOutput = try JSONSerialization.jsonObject(with: encoder.encode(missing)) as! [String: Any]
    c.check(jsonOutput["missingResources"] as? [String] == missing.missingResources, "缺失资源列表写入JSON而非仅内存属性")
    let unfamiliar = try report([["newObjectType": "future"]])
    c.check(unfamiliar.layers[0].kind == "unknown" && unfamiliar.issues.contains { $0.code == "unsupportedObject" }, "未知对象不伪装纯变换节点")
    let malformedHierarchy = try report([["parent": [1,2], "objects": "bad"]])
    c.check(malformedHierarchy.issues.contains { $0.code == "invalidParent" } && malformedHierarchy.issues.contains { $0.code == "invalidChildren" }, "非法父级和子列表明确报告")
    let publicJSON = try WESceneInspection.resourceReport(packageData: Data(package(scene([layer])).bytes))
    let publicReport = try JSONDecoder().decode(SceneResourceReport.self, from: publicJSON)
    c.check(publicReport.edges.count == 3 && !publicReport.playable, "公共Data入口使用同一核心解析实现")
    let capabilityData = try WESceneInspection.capabilityReport(packageData: Data(package(scene([layer])).bytes))
    let capability = try JSONDecoder().decode(WESceneCapabilityReport.self, from: capabilityData)
    c.check(capability.resourceInspectionAvailable && !capability.desktopScenePlayable && !capability.faithfulSceneRendering,
            "能力报告不把资源齐全误认成桌面可播放")
    c.check(!capability.restrictedStaticPreviewAvailable && capability.previewFailure != nil &&
            capability.limitationCodes.contains("restrictedPreviewUnavailable"), "预览失败仍保留资源检查与显式限制")
    c.check(rejects { _ = try WESceneInspection.capabilityReport(packageData: Data(package(scene([layer])).bytes), maxPreviewDimension: 961) },
            "能力报告拒绝越界预览尺寸")
}
