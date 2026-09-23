import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func runTextureChecks(_ c: inout Checker) throws {
    func rejects(_ operation: () throws -> Void) -> Bool {
        do { try operation(); return false } catch { return true }
    }
    c.check(rejects { _ = try checkedRGBAByteCount(width: Int.max, height: 2) }, "超大尺寸拒绝且无乘法溢出")
    c.check(rejects { _ = try checkedRGBAByteCount(width: -1, height: 2) }, "负尺寸拒绝")
    c.check(rejects { _ = try lz4BlockDecompress([0x40, 1, 2, 3, 4], expectedSize: 3) }, "LZ4 字面量超预算拒绝")
    c.check(rejects { _ = try lz4BlockDecompress([0x10, 1, 1, 0], expectedSize: 4) }, "LZ4 回引超预算拒绝")
    c.check(rejects { _ = try lz4BlockDecompress([], expectedSize: Int.max) }, "LZ4 声明超限拒绝")
    func rawTex(_ format: TexPixelFormat, flags: Int = 0, video: Bool = false) -> TexFile {
        TexFile(format: format, flags: flags, textureWidth: 2, textureHeight: 2, imageWidth: 2, imageHeight: 2,
                containerMagic: "TEXB0004", imageFormat: .unknown, isVideoTexture: video, images: [])
    }
    let short = TexMipmap(width: 2, height: 2, isLZ4: false, decompressedSize: 0, rawBytes: [1])
    for format in [TexPixelFormat.r8, .rg88, .rgba8888] {
        c.check(rejects { _ = try texMipmapToRGBA(rawTex(format), mipmap: short) }, "截断 \(format.name) 拒绝")
    }
    c.check(rejects { _ = try texMipmapToRGBA(rawTex(.r8, flags: 4), mipmap: short) }, "GIF 拒绝静默首帧")
    c.check(rejects { _ = try texMipmapToRGBA(rawTex(.r8, video: true), mipmap: short) }, "视频纹理拒绝静默首帧")
    let r8Full = TexMipmap(width: 2, height: 2, isLZ4: false, decompressedSize: 0, rawBytes: [10,20,30,40])
    let rgFull = TexMipmap(width: 2, height: 2, isLZ4: false, decompressedSize: 0, rawBytes: [10,20,30,40,50,60,70,80])
    let r8 = try texMipmapToRGBA(rawTex(.r8), mipmap: r8Full)
    let rg = try texMipmapToRGBA(rawTex(.rg88), mipmap: rgFull)
    c.check(Array(r8.rgba.prefix(4)) == [10,10,10,255], "R8 通道展开")
    c.check(Array(rg.rgba.prefix(4)) == [10,20,0,255], "RG88 通道展开")
    let a = try makeSyntheticTexRGBA4x4(pixels: [UInt8](repeating: 255, count: 64))
    let b = try makeSyntheticTexRGBA4x4(pixels: [UInt8](repeating: 127, count: 64))
    let cache = TextureCache(budget: 64)
    _ = try cache.load(a); _ = try cache.load(a)
    c.check(cache.hits == 1 && cache.misses == 1 && cache.residentBytes == 64, "内容缓存命中")
    let changed = try cache.load(b)
    c.check(changed.rgba[0] == 127 && cache.residentBytes == 64, "内容改变刷新且 LRU 不超预算")
    _ = try cache.load(a)
    c.check(cache.misses == 3, "被淘汰纹理重新解码")
    c.check(rejects { _ = try cache.load(a, mipLevel: -1) }, "无效 mipmap 拒绝")
    let tiny = TextureCache(budget: 1)
    _ = try tiny.load(a)
    c.check(tiny.residentBytes == 0, "超过缓存预算的单图可用但不驻留")
    cache.removeAll()
    c.check(cache.residentBytes == 0, "显式清空预算归零")
    var brokenPkg = try makeSyntheticPkg(); brokenPkg.removeLast()
    c.check(rejects { _ = try parsePkg(brokenPkg) }, "PKG 解析立即拒绝越界条目")
    c.check(!safePackagePath("../outside") && !safePackagePath("/absolute") && !safePackagePath("a\\b"), "解包拒绝路径穿越")
    c.check(safePackagePath("materials/中文.tex"), "安全中文相对路径保留")
    // TEX 头：18 字节 magic + 28 字节元信息 + 9 字节容器 + 4 字节图像数。
    var realRaw = a
    realRaw.replaceSubrange(59..<63, with: [255,255,255,255])
    c.check(try parseTex(realRaw).imageFormat == .unknown, "真实样本 -1 裸像素标记")
    for version in [3, 4] {
        let disguised = makeSyntheticDisguisedVideoTex(version: version)
        let parsed = try parseTex(disguised)
        c.check(parsed.isVideoTexture && parsed.imageFormat == .mp4, "TEXB000\(version) 未标记 MP4 内容识别")
        c.check(rejects { _ = try texMipmapToRGBA(parsed, mipmap: parsed.images[0].mipmaps[0]) }, "伪装 MP4 不当作裸像素")
        c.check(rejects { _ = try TextureCache().load(disguised) }, "伪装 MP4 不进入静态缓存")
    }
    let extra = TexMipmap(width: 2, height: 2, isLZ4: false, decompressedSize: 0,
                          rawBytes: [UInt8](repeating: 7, count: 17))
    c.check(rejects { _ = try texMipmapToRGBA(rawTex(.rgba8888), mipmap: extra) }, "裸像素多余字节不静默截断")
    var unknown = a
    unknown.replaceSubrange(59..<63, with: [123,0,0,0])
    c.check(rejects { _ = try parseTex(unknown) }, "未知图片码不回退为裸像素")
    let lru = TextureCache(budget: 128)
    let third = try makeSyntheticTexRGBA4x4(pixels: [UInt8](repeating: 50, count: 64))
    _ = try lru.load(a); _ = try lru.load(b); _ = try lru.load(a); _ = try lru.load(third); _ = try lru.load(a)
    c.check(lru.hits == 2 && lru.residentBytes == 128, "LRU 命中更新顺序，保留热纹理")
}

// MARK: - 合成样本（自检用，不需要真实素材）

func u32le(_ v: Int) -> [UInt8] {
    let x = UInt32(truncatingIfNeeded: v)
    return [UInt8(x & 0xFF), UInt8((x >> 8) & 0xFF), UInt8((x >> 16) & 0xFF), UInt8((x >> 24) & 0xFF)]
}

func sizedStringBytes(_ s: String) -> [UInt8] {
    let body = Array(s.utf8)
    return u32le(body.count) + body
}

func nstringBytes(_ s: String) -> [UInt8] {
    Array(s.utf8) + [0]
}

/// 造一个 TEXB0003 容器：RGBA8888 / 4x4 / 1 张图 / 1 级 mipmap（LZ4 压缩，测试解压路径）
func makeSyntheticTexRGBA4x4(pixels: [UInt8]) throws -> Data {
    precondition(pixels.count == 64)

    // LZ4：纯字面量 sequence（合法），64 字节 → token 0xF0 + 扩展长度 49
    var lz4: [UInt8] = [0xF0, 49]
    lz4.append(contentsOf: pixels)

    var out: [UInt8] = []
    out += nstringBytes("TEXV0005")
    out += nstringBytes("TEXI0001")
    out += u32le(TexPixelFormat.rgba8888.rawValue)   // format
    out += u32le(0)                                  // flags
    out += u32le(4) + u32le(4)                       // texture w/h
    out += u32le(4) + u32le(4)                       // image w/h
    out += u32le(0)                                  // unk
    out += nstringBytes("TEXB0003")
    out += u32le(1)                                  // image count
    out += u32le(FreeImageFormat.unknown.rawValue)   // 裸像素
    out += u32le(1)                                  // mipmap count
    out += u32le(4) + u32le(4)                       // mipmap w/h
    out += u32le(1)                                  // isLZ4
    out += u32le(64)                                 // decompressed size
    out += u32le(lz4.count) + lz4                    // bytes
    return Data(out)
}

func makeSyntheticDisguisedVideoTex(version: Int) -> Data {
    precondition(version == 3 || version == 4)
    let payload: [UInt8] = [0, 0, 0, 12] + Array("ftypmp42".utf8)
    var out: [UInt8] = []
    out += nstringBytes("TEXV0005") + nstringBytes("TEXI0001")
    out += u32le(TexPixelFormat.rgba8888.rawValue) + u32le(0)
    out += u32le(2) + u32le(2) + u32le(2) + u32le(2) + u32le(0)
    out += nstringBytes(String(format: "TEXB%04d", version))
    out += u32le(1) + u32le(-1)
    if version == 4 { out += u32le(0) } // 视频位未设置，仍须从载荷识别
    out += u32le(1) + u32le(2) + u32le(2)
    out += u32le(0) + u32le(0) + u32le(payload.count) + payload
    return Data(out)
}

/// 造一个 DXT1 的 4x4 块（红色）
func makeSyntheticDXT1Red4x4() -> [UInt8] {
    var block: [UInt8] = []
    block += [0x00, 0xF8]   // c0 = 0xF800 (红)
    block += [0x1F, 0x00]   // c1 = 0x001F (蓝)，c0 > c1 → 4 色模式
    block += [0x00, 0x00, 0x00, 0x00]  // 索引全 0 → 全用 c0
    return block
}

func makeSyntheticDXT1Tex() throws -> Data {
    var out: [UInt8] = []
    out += nstringBytes("TEXV0005")
    out += nstringBytes("TEXI0001")
    out += u32le(TexPixelFormat.dxt1.rawValue)
    out += u32le(0)
    out += u32le(4) + u32le(4) + u32le(4) + u32le(4) + u32le(0)
    out += nstringBytes("TEXB0002")
    out += u32le(1)                     // image count
    out += u32le(1)                     // mipmap count（V2 没有 imageFormat 字段）
    out += u32le(4) + u32le(4)
    out += u32le(0)                     // isLZ4 = 0
    out += u32le(8)                     // decompressed size
    let block = makeSyntheticDXT1Red4x4()
    out += u32le(block.count) + block
    return Data(out)
}

func makeSyntheticSceneJSON() -> Data {
    let json = """
    {
      "camera": { "eye": [0, 0, 1], "center": [0, 0, 0], "up": [0, 1, 0] },
      "general": { "ambientcolor": [0, 0, 0], "bloom": true, "orthogonalprojection": { "width": 1920, "height": 1080 } },
      "objects": [
        { "name": "background", "image": "textures/bg.tex", "origin": [0, 0, 0], "size": [1, 1], "alpha": { "script": "return 1", "value": 1 } },
        { "name": "group1", "objects": [ { "name": "child", "image": "textures/child.tex" } ] }
      ]
    }
    """
    return Data(json.utf8)
}

func makeSyntheticPkg() throws -> Data {
    let sceneJSON = makeSyntheticSceneJSON()
    let tex = try makeSyntheticTexRGBA4x4(pixels: (0..<16).flatMap { i -> [UInt8] in
        [UInt8(i * 16), UInt8(255 - i * 16), 128, 255]
    })

    let entries: [(String, [UInt8])] = [
        ("scene.json", Array(sceneJSON)),
        ("textures/bg.tex", Array(tex)),
    ]

    var header: [UInt8] = sizedStringBytes("PKGV0019")
    header += u32le(entries.count)
    var offset = 0
    for (path, data) in entries {
        header += sizedStringBytes(path)
        header += u32le(offset)
        header += u32le(data.count)
        offset += data.count
    }
    var out = header
    for (_, data) in entries { out += data }
    return Data(out)
}

// MARK: - 自检

struct Checker {
    var failures: [String] = []
    var passes = 0

    mutating func check(_ condition: Bool, _ label: String) {
        if condition { passes += 1; print("  ✅ \(label)") }
        else { failures.append(label); print("  ❌ \(label)") }
    }
}

func runSelfTest() throws {
    var c = Checker()
    print("=== WESceneProbe 自检（合成样本，不使用真实素材）===")

    // 1) LZ4
    print("\n[1] LZ4 block 解压")
    let literalOnly: [UInt8] = [0x40, 1, 2, 3, 4]
    let decoded1 = try lz4BlockDecompress(literalOnly, expectedSize: 4)
    c.check(decoded1 == [1, 2, 3, 4], "纯字面量块")

    let withMatch: [UInt8] = [0x80, 1, 2, 3, 4, 5, 6, 7, 8, 0x08, 0x00]
    let decoded2 = try lz4BlockDecompress(withMatch, expectedSize: 12)
    c.check(decoded2 == [1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4], "带匹配块（offset=8, len=4）")

    // 2) DXT1
    print("\n[2] DXT1 解码")
    let rgba = try decodeDXT(makeSyntheticDXT1Red4x4(), width: 4, height: 4, kind: .dxt1)
    c.check(rgba.count == 64, "输出 16 像素")
    c.check(rgba[0] == 255 && rgba[1] == 0 && rgba[2] == 0 && rgba[3] == 255, "首像素为不透明白色的红 (255,0,0,255)，实际 \(rgba[0]),\(rgba[1]),\(rgba[2]),\(rgba[3])")

    // 3) PKGV
    print("\n[3] PKGV 容器")
    let pkgData = try makeSyntheticPkg()
    let pkg = try parsePkg(pkgData)
    c.check(pkg.magic == "PKGV0019", "magic = PKGV0019")
    c.check(pkg.entries.count == 2, "条目数 = 2")
    c.check(pkg.entries.map(\.path) == ["scene.json", "textures/bg.tex"], "条目路径正确")
    let sceneBytes = try pkg.data(of: pkg.entries[0])
    c.check(sceneBytes.count == makeSyntheticSceneJSON().count, "scene.json 数据长度一致")
    let texBytes = try pkg.data(of: pkg.entries[1])
    c.check(texBytes.count > 100, "textures/bg.tex 取出非空（\(texBytes.count) 字节）")

    // 4) TEX（RGBA8888 + LZ4）
    print("\n[4] TEX 解析（RGBA8888 / LZ4 mipmap）")
    let tex = try parseTex(Data(texBytes))
    c.check(tex.containerMagic == "TEXB0003", "容器 = TEXB0003")
    c.check(tex.format == .rgba8888, "格式 = RGBA8888")
    c.check(tex.images.count == 1 && tex.images[0].mipmaps.count == 1, "1 图 1 mipmap")
    let mip = tex.images[0].mipmaps[0]
    c.check(mip.isLZ4 && mip.decompressedSize == 64, "mipmap 标记为 LZ4 / 64 字节")
    let (w, h, pixels) = try texMipmapToRGBA(tex, mipmap: mip)
    c.check(w == 4 && h == 4 && pixels.count == 64, "解出 4x4 RGBA")

    // 5) TEX（DXT1）
    print("\n[5] TEX 解析（DXT1）")
    let dxtTex = try parseTex(try makeSyntheticDXT1Tex())
    c.check(dxtTex.format == .dxt1, "格式 = DXT1")
    let (_, _, dxtPixels) = try texMipmapToRGBA(dxtTex, mipmap: dxtTex.images[0].mipmaps[0])
    c.check(dxtPixels[0] == 255 && dxtPixels[1] == 0 && dxtPixels[2] == 0, "DXT1 → 红色")

    // 6) scene.json
    print("\n[6] scene.json 摘要")
    let summary = try summarizeScene(makeSyntheticSceneJSON())
    c.check(summary.contains("image"), "识别出 image 对象")
    c.check(summary.contains("group"), "识别出 group 对象")
    c.check(summary.contains("textures/bg.tex"), "列出纹理引用")
    c.check(summary.contains("script"), "统计到 script 多态字段")

    // 7) PNG 导出
    print("\n[7] PNG 导出")
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wescene-selftest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let pngPath = tmp.appendingPathComponent("bg.png").path
    try writePNG(pixels, width: w, height: h, to: pngPath)
    let attrs = try FileManager.default.attributesOfItem(atPath: pngPath)
    let size = (attrs[.size] as? Int) ?? 0
    c.check(size > 50, "PNG 已写出（\(size) 字节）")
    let alphaPath = tmp.appendingPathComponent("alpha.png").path
    try writePNG([200,100,50,128], width: 1, height: 1, to: alphaPath)
    let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: alphaPath) as CFURL, nil)!
    let alphaImage = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    let alpha = try cgImageToRGBA(alphaImage).rgba
    c.check(zip(alpha, [UInt8(200),100,50,128]).allSatisfy { abs(Int($0.0) - Int($0.1)) <= 2 }, "半透明 PNG straight alpha 往返")
    print("  样本目录: \(tmp.path)")

    try runTextureChecks(&c)
    try runResourceChecks(&c)
    try runCompositorChecks(&c)
    print("\n=== 自检结果：通过 \(c.passes) 项，失败 \(c.failures.count) 项 ===")
    if !c.failures.isEmpty {
        for f in c.failures { print("  ❌ \(f)") }
        exit(1)
    }
}
