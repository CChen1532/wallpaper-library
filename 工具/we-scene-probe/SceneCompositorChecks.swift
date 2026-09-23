import Foundation

func makePreviewPackage(objects: [[String: Any]], textures: [String: [UInt8]],
                        projection: (Int, Int) = (4, 4), clear: Bool = false,
                        extraFiles: [(String, Data)] = []) throws -> Data {
    var files: [(String, Data)] = []
    let scene: [String: Any] = [
        "camera": [:],
        "general": ["orthogonalprojection": ["width": projection.0, "height": projection.1],
                    "clearenabled": clear, "clearcolor": "0 0 0"],
        "objects": objects
    ]
    files.append(("scene.json", try JSONSerialization.data(withJSONObject: scene)))
    for (name, pixels) in textures.sorted(by: { $0.key < $1.key }) {
        files.append(("models/\(name).json", try JSONSerialization.data(withJSONObject: ["material": "materials/\(name).json", "width": 4, "height": 4])))
        files.append(("materials/\(name).json", try JSONSerialization.data(withJSONObject: ["passes": [["textures": [name], "blending": "translucent"]]])))
        files.append(("materials/\(name).tex", try makeSyntheticTexRGBA4x4(pixels: pixels)))
    }
    files.append(contentsOf: extraFiles)
    var header = sizedStringBytes("PKGV0024") + u32le(files.count)
    var offset = 0
    for (path, bytes) in files {
        header += sizedStringBytes(path) + u32le(offset) + u32le(bytes.count)
        offset += bytes.count
    }
    for (_, bytes) in files { header += bytes }
    return Data(header)
}

func runCompositorChecks(_ c: inout Checker) throws {
    func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) -> [UInt8] {
        Array(repeating: [r,g,b,a], count: 16).flatMap { $0 }
    }
    func image(_ name: String, id: Int, extra: [String: Any] = [:]) -> [String: Any] {
        var object: [String: Any] = ["id": id, "image": "models/\(name).json", "origin": "2 2 0", "size": "4 4"]
        object.merge(extra) { _, new in new }
        return object
    }
    func render(_ objects: [[String: Any]], textures: [String: [UInt8]], edge: Int = 4,
                projection: (Int, Int) = (4,4)) throws -> WESceneStaticPreview {
        try WESceneInspection.staticPreview(packageData: makePreviewPackage(objects: objects, textures: textures, projection: projection), maxDimension: edge)
    }
    func pixel(_ preview: WESceneStaticPreview, _ x: Int, _ y: Int) -> [UInt8] {
        let pos = (y * preview.width + x) * 4
        return Array(preview.rgba[pos..<(pos+4)])
    }
    func summary(_ preview: WESceneStaticPreview) throws -> PreviewSummary { try JSONDecoder().decode(PreviewSummary.self, from: preview.diagnosticsJSON) }
    func rejects(_ block: () throws -> Void) -> Bool { do { try block(); return false } catch { return true } }

    let red = solid(255, 0, 0), blue = solid(0, 0, 255)
    let base = try render([image("red", id: 1)], textures: ["red": red])
    c.check(base.width == 4 && base.height == 4 && pixel(base, 0, 0) == [255,0,0,255] && pixel(base, 3, 3) == [255,0,0,255], "基础图覆盖与边界像素")
    let capabilityData = try WESceneInspection.capabilityReport(
        packageData: makePreviewPackage(objects: [image("red", id: 1)], textures: ["red": red]),
        maxPreviewDimension: 4)
    let capability = try JSONDecoder().decode(WESceneCapabilityReport.self, from: capabilityData)
    c.check(capability.restrictedStaticPreviewAvailable && capability.previewFailure == nil &&
            !capability.desktopScenePlayable && !capability.faithfulSceneRendering,
            "受限静态预览可用仍不解锁桌面动态播放")
    c.check(try !summary(base).playable && !summary(base).faithful, "静态导出不宣称可播放或忠实还原")
    c.check(try base.hasRenderableContent && summary(base).previewAvailable, "有基础图层才标记预览可用")
    c.check(try summary(base).frameMode == "staticApproximation" && summary(base).videoTexture == nil, "静态与视频帧报告分开标记")
    let sharedPackage = try parsePkg(makePreviewPackage(objects: [image("red", id: 1)], textures: ["red": red]))
    let sharedCache = TextureCache()
    let firstCached = try SceneCompositor(package: sharedPackage, textureCache: sharedCache).render(maxDimension: 4)
    c.check(sharedCache.misses == 1 && sharedCache.hits == 0 && sharedCache.residentBytes > 0,
            "首次静态纹理解码进入会话缓存")
    let secondCached = try SceneCompositor(package: sharedPackage, textureCache: sharedCache).render(maxDimension: 4)
    c.check(sharedCache.misses == 1 && sharedCache.hits == 1 &&
            firstCached.rgba == secondCached.rgba, "下一帧静态纹理命中缓存且画面相同")
    sharedCache.removeAll()
    c.check(sharedCache.residentBytes == 0, "会话结束清空静态纹理缓存")
    let injected = WESceneVideoTextureFrame(width: 4, height: 4, rgba: Data(blue),
                                            durationSeconds: 2, requestedSeconds: 1,
                                            actualSeconds: 1, texturePath: "materials/red.tex")
    let injectedPackage = try parsePkg(makePreviewPackage(objects: [image("red", id: 1)], textures: ["red": red]))
    let frame = try SceneCompositor(package: injectedPackage, videoFrame: injected).render(maxDimension: 4)
    c.check(pixel(frame, 1, 1) == [0,0,255,255], "视频帧按同一路径替换静态贴图")
    c.check(try summary(frame).frameMode == "offlineVideoTextureFrame" &&
            summary(frame).requestedSeconds == 1 && summary(frame).actualSeconds == 1 &&
            summary(frame).videoDurationSeconds == 2 &&
            !summary(frame).playable && !summary(frame).faithful, "离线动态帧不冒充桌面可播放")
    let windowless = try SceneCompositor(package: injectedPackage, videoFrame: injected,
                                          videoFrameKind: .windowlessProbe).render(maxDimension: 4)
    c.check(try summary(windowless).frameMode == "windowlessRealtimeProbe" &&
            summary(windowless).diagnostics.contains { $0.code == "windowlessVideoFrame" } &&
            !summary(windowless).playable && !summary(windowless).faithful,
            "无窗口视频帧与离线帧分开诊断且不冒充桌面scene")
    let unrelated = WESceneVideoTextureFrame(width: 4, height: 4, rgba: Data(blue),
                                             durationSeconds: 2, requestedSeconds: 1,
                                             actualSeconds: 1, texturePath: "materials/unused.tex")
    c.check(rejects { _ = try SceneCompositor(package: injectedPackage, videoFrame: unrelated).render(maxDimension: 4) },
            "未被图层使用的视频帧不冒充动态合成")

    var pattern: [UInt8] = []
    for y in 0..<4 { for _ in 0..<4 { pattern += y == 0 ? [255,0,0,255] : [0,0,255,255] } }
    let oriented = try render([image("pattern", id: 1)], textures: ["pattern": pattern])
    c.check(pixel(oriented, 0, 0) == [255,0,0,255] && pixel(oriented, 0, 3) == [0,0,255,255], "纹理与画布Y轴各翻转一次")

    let over = try render([image("red", id: 1), image("blue", id: 2, extra: ["alpha": 0.5])], textures: ["red": red, "blue": blue])
    let middle = pixel(over, 1, 1)
    c.check(abs(Int(middle[0])-127) <= 1 && middle[1] == 0 && abs(Int(middle[2])-128) <= 1 && middle[3] == 255, "半透明图层标准source-over")
    let alphaOnly = try render([image("blue", id: 2, extra: ["alpha": 0.5])], textures: ["blue": blue])
    c.check(pixel(alphaOnly, 1, 1) == [0,0,255,128], "straight RGBA只乘一次图层alpha")
    let reversed = try render([image("blue", id: 2), image("red", id: 1)], textures: ["red": red, "blue": blue])
    c.check(pixel(reversed, 1, 1) == [255,0,0,255], "后绘制图层覆盖先绘制图层")

    let node: [String: Any] = ["id": 10, "origin": "1 0 0", "scale": "1 1 1", "objects": [image("blue", id: 2, extra: ["origin": "2 2 0", "size": "2 2"] )]]
    let child = try render([image("red", id: 1), node], textures: ["red": red, "blue": blue])
    c.check(pixel(child, 0, 1) == [255,0,0,255] && pixel(child, 3, 1) == [0,0,255,255], "无图像父节点平移传递到子层")

    let transform = Affine2.local(origin: Point2(x: 5, y: 7), scale: Point2(x: 2, y: 3), angle: .pi/2)
        .combined(with: .local(origin: Point2(x: 1, y: 0), scale: Point2(x: 1, y: 1), angle: 0))
    let result = transform.apply(Point2(x: 0, y: 0))
    c.check(abs(result.x-5) < 0.0001 && abs(result.y-9) < 0.0001, "父平移旋转缩放与子位置矩阵复合")
    let negative = try render([image("pattern", id: 1, extra: ["scale": "-1 1 1"])], textures: ["pattern": pattern])
    c.check(pixel(negative, 0, 0) == [255,0,0,255], "负缩放可逆且确定")

    let hidden = try render([image("red", id: 1, extra: ["visible": false])], textures: ["red": red])
    c.check(pixel(hidden, 0, 0) == [0,0,0,0], "不可见层不绘制")
    c.check(try !hidden.hasRenderableContent && !summary(hidden).previewAvailable, "无可见基础图层不冒充可用预览")
    let zero = try render([image("blue", id: 2, extra: ["scale": "0 1 1"])], textures: ["blue": blue])
    c.check(try summary(zero).skippedLayers.count == 1 && pixel(zero, 1, 1) == [0,0,0,0], "零缩放明确跳过")
    let absent = try render([image("red", id: 1, extra: ["parent": 999])], textures: ["red": red])
    c.check(try summary(absent).skippedLayers.count == 1, "缺失父层不崩溃且明确跳过")
    let cycle = try render([image("red", id: 1, extra: ["parent": 2]), image("blue", id: 2, extra: ["parent": 1])], textures: ["red": red, "blue": blue])
    c.check(try summary(cycle).skippedLayers.count == 2, "父级循环两层均跳过")
    let invalid = try render([image("red", id: 1, extra: ["origin": "nan 2 0"])], textures: ["red": red])
    c.check(try summary(invalid).skippedLayers.count == 1, "非有限坐标明确跳过")
    let blend = try render([image("red", id: 1, extra: ["colorBlendMode": 7])], textures: ["red": red])
    c.check(try summary(blend).skippedLayers.count == 1, "未知混合模式不误画为source-over")
    let effects = try render([image("red", id: 1, extra: ["effects": [["file": "effects/a.json"]]])], textures: ["red": red])
    c.check(try summary(effects).diagnostics.contains { $0.code == "effectsOmitted" }, "效果器省略有诊断")

    let keyDefinition = try JSONSerialization.data(withJSONObject: [
        "version": 1, "replacementkey": "colorkey",
        "passes": [["material": "materials/effects/colorkey.json"]]
    ])
    let keyMaterial = try JSONSerialization.data(withJSONObject: [
        "passes": [["shader": "effects/colorkey", "blending": "normal"]]
    ])
    let keyFiles = [("effects/colorkey/effect.json", keyDefinition),
                    ("materials/effects/colorkey.json", keyMaterial)]
    func keyed(_ constants: [String: Any], extra: [String: Any] = [:]) -> [String: Any] {
        var effect: [String: Any] = ["file": "effects/colorkey/effect.json",
                                     "passes": [["constantshadervalues": constants]], "visible": true]
        effect.merge(extra) { _, new in new }
        return image("foreground", id: 2, extra: ["effects": [effect]])
    }
    let keyValues: [String: Any] = ["color": "1 1 0", "alpha": 0,
                                    "fuzziness": 0.1, "tolerance": 0.3]
    func keyRender(_ foreground: [UInt8], _ layer: [String: Any]) throws -> WESceneStaticPreview {
        try WESceneInspection.staticPreview(packageData: makePreviewPackage(
            objects: [image("background", id: 1), layer],
            textures: ["background": blue, "foreground": foreground], extraFiles: keyFiles), maxDimension: 4)
    }
    let removed = try keyRender(solid(255,255,0), keyed(keyValues))
    c.check(pixel(removed, 1, 1) == [0,0,255,255], "colorkey 精确键色露出下层")
    c.check(try summary(removed).diagnostics.contains { $0.code == "colorKeyApproximation" } &&
            !summary(removed).playable && !summary(removed).faithful, "colorkey 仍报告离线近似和不可播放")
    let retained = try keyRender(red, keyed(keyValues))
    c.check(pixel(retained, 1, 1) == [255,0,0,255], "colorkey 远离键色保持不透明")
    let partial = try keyRender(solid(255, 170, 0), keyed(keyValues))
    let partialPixel = pixel(partial, 1, 1)
    c.check(partialPixel[0] > 0 && partialPixel[0] < 255 && partialPixel[2] > 0 && partialPixel[2] < 255,
            "colorkey 平滑边缘与下层混合")
    let preservedAlpha = try keyRender(solid(255,255,0,128), keyed([
        "color": "1 1 0", "alpha": 0.5, "fuzziness": 0.1, "tolerance": 0.3
    ]))
    c.check(abs(Int(pixel(preservedAlpha, 1, 1)[0]) - 64) <= 2, "colorkey 输出透明度与原始alpha相乘")
    let disabled = try keyRender(solid(255,255,0), keyed(keyValues, extra: ["visible": false]))
    c.check(pixel(disabled, 1, 1) == [255,255,0,255], "禁用colorkey按原图绘制")
    let malformed = try keyRender(solid(255,255,0), keyed([
        "color": "1 1 0", "alpha": 0, "fuzziness": 0.1, "tolerance": 9
    ]))
    c.check(try summary(malformed).skippedLayers.count == 1 && pixel(malformed, 1, 1) == [0,0,255,255],
            "越界colorkey参数拒绝该层而非显示错误背景")
    let unsupportedCombo = try keyRender(solid(255,255,0), keyed(keyValues, extra: ["combos": ["INVERT": 1]]))
    c.check(try summary(unsupportedCombo).skippedLayers.count == 1, "未实现反选组合明确拒绝")

    var padded = pattern
    for y in 0..<4 { for x in 2..<4 { let p = (y*4+x)*4; padded[p]=0; padded[p+1]=255; padded[p+2]=0 } }
    var tex = try makeSyntheticTexRGBA4x4(pixels: padded)
    tex.replaceSubrange(34..<38, with: u32le(2)) // imageWidth=2, mipmap仍4像素宽
    let model = try makePreviewPackage(objects: [image("pattern", id: 1)], textures: ["pattern": pattern])
    let package = try parsePkg(model)
    let entry = package.entries.first { $0.path == "materials/pattern.tex" }!
    var packageBytes = package.bytes
    packageBytes.replaceSubrange((package.dataStart+entry.offset)..<(package.dataStart+entry.offset+entry.length), with: [UInt8](tex))
    let crop = try WESceneInspection.staticPreview(packageData: Data(packageBytes), maxDimension: 4)
    c.check(pixel(crop, 3, 1) != [0,255,0,255], "mipmap填充区不泄露到裁剪画面")

    let small = try render([image("red", id: 1)], textures: ["red": red], edge: 2)
    c.check(small.width == 2 && small.height == 2 && small.rgba.count == 16, "缩小画布边界准确")
    c.check(rejects { _ = try WESceneInspection.staticPreview(packageData: model, maxDimension: 0) }, "非法预览尺寸拒绝")
}
