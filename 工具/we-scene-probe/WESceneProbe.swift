import Foundation

// MARK: - 命令

func usage() {
    print("""
    用法:
      we-scene-probe selftest                 合成样本自检（不需要真实素材）
      we-scene-probe pkg <scene.pkg>          列出 PKGV 条目
      we-scene-probe extract <pkg> <outdir>   解包
      we-scene-probe tex <file.tex> [out.png] 解析 TEX，可导出首张图 PNG
      we-scene-probe video-payload <file.tex> <out.mp4> 只提取已识别视频纹理载荷（拒绝覆盖）
      we-scene-probe scene <scene.json>       打印场景结构摘要
      we-scene-probe audit <scene.pkg>        只读解码所有 TEX，明确列出不支持项
      we-scene-probe resources <scene.pkg>    输出资源引用与能力 JSON（非渲染）
      we-scene-probe still <scene.pkg> <out.png> [max-edge]  导出静态基础图及同名 .json 诊断
      we-scene-probe frame <scene.pkg> <materials/name.tex> <seconds> <out.png> [max-edge]  离线视频纹理取帧并合成
    """)
}

@main enum WESceneProbeCLI {
static func main() async {
let args = CommandLine.arguments
guard args.count >= 2 else { usage(); exit(2) }

do {
    switch args[1] {
    case "selftest":
        try runSelfTest()

    case "pkg":
        guard args.count >= 3 else { usage(); exit(2) }
        let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        let pkg = try parsePkg(data)
        print("容器: \(pkg.magic)　条目数: \(pkg.entries.count)　数据区起点: \(pkg.dataStart)")
        for e in pkg.entries {
            print(String(format: "  %-50s offset=%-10d length=%d", (e.path as NSString).utf8String!, e.offset, e.length))
        }

    case "extract":
        guard args.count >= 4 else { usage(); exit(2) }
        let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        let pkg = try parsePkg(data)
        let outDir = URL(fileURLWithPath: args[3])
        let named = pkg.entries.filter { !$0.path.isEmpty }
        guard named.allSatisfy({ safePackagePath($0.path) }), Set(named.map { $0.path.lowercased() }).count == named.count else {
            throw ProbeError.invalid("包内包含不安全路径或重复路径，拒绝解包")
        }
        guard !FileManager.default.fileExists(atPath: outDir.path) else { throw ProbeError.invalid("解包要求全新输出目录，拒绝覆盖") }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: false)
        for e in named {
            let dest = outDir.appendingPathComponent(e.path)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(try pkg.data(of: e)).write(to: dest, options: .withoutOverwriting)
        }
        print("已解出 \(named.count) 个条目；跳过 \(pkg.entries.count - named.count) 个空路径 → \(outDir.path)")

    case "tex":
        guard args.count >= 3 else { usage(); exit(2) }
        let tex = try parseTex(try Data(contentsOf: URL(fileURLWithPath: args[2])))
        print("容器: \(tex.containerMagic)　格式: \(tex.format.name)　内嵌图片格式: \(tex.imageFormat.name)")
        print("纹理尺寸: \(tex.textureWidth)x\(tex.textureHeight)　图像尺寸: \(tex.imageWidth)x\(tex.imageHeight)　GIF: \(tex.isGIF)")
        print("图像数: \(tex.images.count)")
        for (i, img) in tex.images.enumerated() {
            print("  [\(i)] mipmap 数: \(img.mipmaps.count)")
            for (j, m) in img.mipmaps.enumerated() {
                print("      mip\(j): \(m.width)x\(m.height) lz4=\(m.isLZ4) raw=\(m.rawBytes.count) 解压后=\(m.decompressedSize)")
            }
        }
        if args.count >= 4, let first = tex.images.first?.mipmaps.first {
            let (w, h, rgba) = try texMipmapToRGBA(tex, mipmap: first)
            try writePNG(rgba, width: w, height: h, to: args[3])
            print("已导出 PNG: \(args[3]) (\(w)x\(h))")
        }

    case "video-payload":
        guard args.count == 4 else { usage(); exit(2) }
        let tex = try parseTex(Data(contentsOf: URL(fileURLWithPath: args[2])))
        let bytes = try SceneVideoTextureDecoder.payload(tex)
        try Data(bytes).write(to: URL(fileURLWithPath: args[3]), options: .withoutOverwriting)
        print("已提取包内 MP4 载荷：\(bytes.count) 字节；仅用于离线检查")

    case "scene":
        guard args.count >= 3 else { usage(); exit(2) }
        print(try summarizeScene(try Data(contentsOf: URL(fileURLWithPath: args[2]))))

    case "audit":
        guard args.count == 3 else { usage(); exit(2) }
        let pkg = try parsePkg(Data(contentsOf: URL(fileURLWithPath: args[2])))
        let cache = TextureCache()
        var success = 0, rejected = 0
        for entry in pkg.entries where entry.path.lowercased().hasSuffix(".tex") {
            do {
                let texture = try cache.load(Data(pkg.data(of: entry)))
                success += 1
                print("OK \(entry.path) \(texture.width)x\(texture.height) \(texture.sourceFormat.name) / \(texture.embeddedFormat.name)")
            } catch {
                rejected += 1
                print("REJECT \(entry.path): \(error)")
            }
        }
        print("AUDIT decoded=\(success) rejected=\(rejected) cacheBytes=\(cache.residentBytes)")
        if rejected > 0 { exit(3) }

    case "resources":
        guard args.count == 3 else { usage(); exit(2) }
        let pkg = try parsePkg(Data(contentsOf: URL(fileURLWithPath: args[2])))
        let report = try SceneResourceInspector(package: pkg).inspect()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
        if !report.issues.isEmpty { exit(3) }

    case "still":
        guard (4...5).contains(args.count) else { usage(); exit(2) }
        let maxEdge = args.count == 5 ? (Int(args[4]) ?? 0) : 1600
        let image = try WESceneInspection.staticPreview(packageData: Data(contentsOf: URL(fileURLWithPath: args[2])), maxDimension: maxEdge)
        let output = URL(fileURLWithPath: args[3])
        try image.diagnosticsJSON.write(to: output.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
        guard image.hasRenderableContent else {
            FileHandle.standardError.write("无可合成的静态内容；仅写出诊断JSON，未生成PNG\n".data(using: .utf8)!)
            exit(3)
        }
        try writePNG([UInt8](image.rgba), width: image.width, height: image.height, to: output.path)
        print("静态基础图: \(output.path) (\(image.width)x\(image.height))；同名JSON记录降级项，非可播放壁纸")

    case "frame":
        guard (6...7).contains(args.count), let seconds = Double(args[4]) else { usage(); exit(2) }
        let maxEdge = args.count == 7 ? (Int(args[6]) ?? 0) : 1600
        let image = try await WESceneInspection.offlineFrame(
            packageData: Data(contentsOf: URL(fileURLWithPath: args[2])),
            videoTexturePath: args[3], atSeconds: seconds, maxDimension: maxEdge)
        let output = URL(fileURLWithPath: args[5])
        try image.diagnosticsJSON.write(to: output.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
        guard image.hasRenderableContent else {
            FileHandle.standardError.write("无可合成内容；仅写出诊断JSON，未生成PNG\n".data(using: .utf8)!)
            exit(3)
        }
        try writePNG([UInt8](image.rgba), width: image.width, height: image.height, to: output.path)
        print("离线帧: \(output.path) (\(image.width)x\(image.height))；同名JSON记录请求/实际时间与降级项，非桌面播放")

    default:
        usage(); exit(2)
    }
} catch {
    FileHandle.standardError.write("错误: \(error)\n".data(using: .utf8)!)
    exit(1)
}
}
}
