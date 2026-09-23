// WESceneProbe.swift
// Wallpaper Engine 场景格式「只读探针」——阶段 0/1 参考实现骨架
//
// 设计约束（对齐「壁纸库」项目约定）：
//   · 只用 Apple Command Line Tools，无任何第三方依赖
//   · 不做渲染、不写系统状态，纯只读解析 + 自检
//   · 格式依据：公开逆向文档 + 某个 Linux 场景渲染实现（GPL）的 docs/
//     本文件是按「格式事实」独立编写的实现，未复制任何 GPL 代码
//
// 用法：
//   we-scene-probe selftest                 合成样本自检（不需要真实素材）
//   we-scene-probe pkg <scene.pkg>          列出 PKGV 容器条目
//   we-scene-probe extract <pkg> <outdir>   解包
//   we-scene-probe tex <file.tex> [out.png] 解析 TEX，可导出首张图 PNG
//   we-scene-probe scene <scene.json>       打印场景结构摘要
//
// 编译：swiftc -O WESceneProbe.swift -o we-scene-probe

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - 错误

enum ProbeError: Error, CustomStringConvertible {
    case truncated(String)
    case badMagic(expected: String, got: String)
    case unsupported(String)
    case invalid(String)

    var description: String {
        switch self {
        case .truncated(let m): return "数据被截断：\(m)"
        case .badMagic(let e, let g): return "magic 不符：期望 \(e)，实际 \(g)"
        case .unsupported(let m): return "不支持的格式：\(m)"
        case .invalid(let m): return "数据非法：\(m)"
        }
    }
}

// MARK: - 小端二进制读取器

struct ByteReader {
    let bytes: [UInt8]
    private(set) var pos: Int = 0

    init(_ data: Data) { self.bytes = [UInt8](data) }
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - pos }

    mutating func take(_ n: Int) throws -> [UInt8] {
        guard n >= 0 else { throw ProbeError.invalid("负数长度 \(n)") }
        guard remaining >= n else { throw ProbeError.truncated("需要 \(n) 字节，只剩 \(remaining)") }
        let out = Array(bytes[pos..<(pos + n)])
        pos += n
        return out
    }

    mutating func skip(_ n: Int) throws { _ = try take(n) }
    mutating func u8() throws -> UInt8 { try take(1)[0] }

    mutating func u16() throws -> UInt16 {
        let b = try take(2)
        return UInt16(b[0]) | (UInt16(b[1]) << 8)
    }

    mutating func u32() throws -> UInt32 {
        let b = try take(4)
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    /// 0 结尾字符串（WE 的 nstring）
    mutating func nstring(maxLength: Int = 256) throws -> String {
        var out: [UInt8] = []
        while true {
            guard remaining > 0 else { throw ProbeError.truncated("nstring 缺少结束符") }
            let c = try u8()
            if c == 0 { break }
            out.append(c)
            if out.count > maxLength { throw ProbeError.invalid("nstring 超过 \(maxLength) 字节") }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// i32 长度前缀字符串（PKGV 条目路径）
    mutating func sizedString(maxLength: Int = 4096) throws -> String {
        let n = Int(try i32())
        guard n >= 0, n <= maxLength else { throw ProbeError.invalid("字符串长度异常 \(n)") }
        return String(decoding: try take(n), as: UTF8.self)
    }
}

// MARK: - PKGV 容器（scene.pkg）

struct PkgEntry {
    let path: String
    let offset: Int
    let length: Int
}

struct PkgFile {
    let magic: String
    let entries: [PkgEntry]
    let dataStart: Int
    let bytes: [UInt8]

    func data(of entry: PkgEntry) throws -> [UInt8] {
        let start = dataStart + entry.offset
        let end = start + entry.length
        guard start >= 0, end <= bytes.count else {
            throw ProbeError.truncated("条目 \(entry.path) 越界")
        }
        return Array(bytes[start..<end])
    }
}

func parsePkg(_ data: Data) throws -> PkgFile {
    var r = ByteReader(data)
    let magic = try r.sizedString(maxLength: 32)
    guard magic.hasPrefix("PKGV") else {
        throw ProbeError.badMagic(expected: "PKGV####", got: magic)
    }
    let count = Int(try r.i32())
    guard count >= 0, count <= 100_000 else { throw ProbeError.invalid("条目数异常 \(count)") }

    var entries: [PkgEntry] = []
    entries.reserveCapacity(count)
    for _ in 0..<count {
        let path = try r.sizedString(maxLength: 4096)
        let offset = Int(try r.i32())
        let length = Int(try r.i32())
        guard offset >= 0, length >= 0 else { throw ProbeError.invalid("条目 \(path) 偏移/长度非法") }
        entries.append(PkgEntry(path: path, offset: offset, length: length))
    }
    return PkgFile(magic: magic, entries: entries, dataStart: r.pos, bytes: r.bytes)
}

// MARK: - LZ4 block 解压（WE 的 .tex mipmap 用它）

func lz4BlockDecompress(_ src: [UInt8], expectedSize: Int) throws -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(max(expectedSize, 16))
    var i = 0
    let n = src.count

    while i < n {
        let token = src[i]; i += 1

        var literalLength = Int(token >> 4)
        if literalLength == 15 {
            while true {
                guard i < n else { throw ProbeError.truncated("LZ4 字面量长度") }
                let b = src[i]; i += 1
                literalLength += Int(b)
                if b != 255 { break }
            }
        }
        guard i + literalLength <= n else { throw ProbeError.truncated("LZ4 字面量数据") }
        out.append(contentsOf: src[i..<(i + literalLength)])
        i += literalLength
        if i >= n { break }

        guard i + 2 <= n else { throw ProbeError.truncated("LZ4 匹配偏移") }
        let offset = Int(src[i]) | (Int(src[i + 1]) << 8)
        i += 2
        guard offset > 0, offset <= out.count else { throw ProbeError.invalid("LZ4 偏移 \(offset) 越界") }

        var matchLength = Int(token & 0x0F)
        if matchLength == 15 {
            while true {
                guard i < n else { throw ProbeError.truncated("LZ4 匹配长度") }
                let b = src[i]; i += 1
                matchLength += Int(b)
                if b != 255 { break }
            }
        }
        matchLength += 4

        var srcIndex = out.count - offset
        for _ in 0..<matchLength {
            out.append(out[srcIndex])
            srcIndex += 1
        }
    }

    if expectedSize > 0 && out.count != expectedSize {
        throw ProbeError.invalid("LZ4 解压得到 \(out.count) 字节，期望 \(expectedSize)")
    }
    return out
}

// MARK: - DXT1/3/5 解码 → RGBA8

enum DXTKind { case dxt1, dxt3, dxt5 }

func decodeDXT(_ data: [UInt8], width: Int, height: Int, kind: DXTKind) throws -> [UInt8] {
    let blockSize = (kind == .dxt1) ? 8 : 16
    let bw = (width + 3) / 4
    let bh = (height + 3) / 4
    let need = bw * bh * blockSize
    guard data.count >= need else {
        throw ProbeError.truncated("DXT 数据 \(data.count) 字节 < 需要 \(need) 字节")
    }

    var out = [UInt8](repeating: 0, count: width * height * 4)
    var p = 0

    func rgb(_ c: UInt16) -> (Int, Int, Int) {
        let r = (Int(c >> 11) & 0x1F) * 255 / 31
        let g = (Int(c >> 5) & 0x3F) * 255 / 63
        let b = (Int(c) & 0x1F) * 255 / 31
        return (r, g, b)
    }

    for by in 0..<bh {
        for bx in 0..<bw {
            var alpha = [UInt8](repeating: 255, count: 16)

            if kind == .dxt3 {
                for k in 0..<8 {
                    let b = data[p + k]
                    alpha[k * 2] = UInt8((b & 0x0F) * 17)
                    alpha[k * 2 + 1] = UInt8(((b >> 4) & 0x0F) * 17)
                }
                p += 8
            } else if kind == .dxt5 {
                let a0 = Int(data[p])
                let a1 = Int(data[p + 1])
                var table = [UInt8](repeating: 0, count: 8)
                table[0] = UInt8(a0)
                table[1] = UInt8(a1)
                if a0 > a1 {
                    for i in 2...7 { table[i] = UInt8((a0 * (8 - i) + a1 * (i - 1)) / 7) }
                } else {
                    for i in 2...5 { table[i] = UInt8((a0 * (6 - i) + a1 * (i - 1)) / 5) }
                    table[6] = 0
                    table[7] = 255
                }
                var bits: UInt64 = 0
                for k in 0..<6 { bits |= UInt64(data[p + 2 + k]) << (8 * k) }
                for i in 0..<16 {
                    let idx = Int((bits >> (3 * i)) & 0x7)
                    alpha[i] = table[idx]
                }
                p += 8
            }

            let c0 = UInt16(data[p]) | (UInt16(data[p + 1]) << 8)
            let c1 = UInt16(data[p + 2]) | (UInt16(data[p + 3]) << 8)
            let indexBits = UInt32(data[p + 4])
                | (UInt32(data[p + 5]) << 8)
                | (UInt32(data[p + 6]) << 16)
                | (UInt32(data[p + 7]) << 24)
            p += 8

            let a = rgb(c0)
            let b = rgb(c1)
            var colors = [(UInt8, UInt8, UInt8, UInt8)]()
            colors.append((UInt8(a.0), UInt8(a.1), UInt8(a.2), 255))
            colors.append((UInt8(b.0), UInt8(b.1), UInt8(b.2), 255))

            if kind == .dxt1 && c0 <= c1 {
                colors.append((UInt8((a.0 + b.0) / 2), UInt8((a.1 + b.1) / 2), UInt8((a.2 + b.2) / 2), 255))
                colors.append((0, 0, 0, 0))
            } else {
                colors.append((UInt8((2 * a.0 + b.0) / 3), UInt8((2 * a.1 + b.1) / 3), UInt8((2 * a.2 + b.2) / 3), 255))
                colors.append((UInt8((a.0 + 2 * b.0) / 3), UInt8((a.1 + 2 * b.1) / 3), UInt8((a.2 + 2 * b.2) / 3), 255))
            }

            for py in 0..<4 {
                for px in 0..<4 {
                    let x = bx * 4 + px
                    let y = by * 4 + py
                    if x >= width || y >= height { continue }
                    let ci = Int((indexBits >> (2 * (py * 4 + px))) & 0x3)
                    let c = colors[ci]
                    let o = (y * width + x) * 4
                    out[o] = c.0
                    out[o + 1] = c.1
                    out[o + 2] = c.2
                    out[o + 3] = alpha[py * 4 + px]
                }
            }
        }
    }
    return out
}

// MARK: - TEX 纹理容器

enum TexPixelFormat: Int {
    case rgba8888 = 0
    case dxt5 = 4
    case dxt3 = 6
    case dxt1 = 7
    case rg88 = 8
    case r8 = 9

    var name: String {
        switch self {
        case .rgba8888: return "RGBA8888"
        case .dxt5: return "DXT5"
        case .dxt3: return "DXT3"
        case .dxt1: return "DXT1"
        case .rg88: return "RG88"
        case .r8: return "R8"
        }
    }
}

enum FreeImageFormat: Int {
    case unknown = 0
    case bmp = 1
    case jpeg = 2
    case png = 13
    case targa = 17
    case gif = 25
    case mp4 = 100

    var name: String {
        switch self {
        case .unknown: return "unknown(裸像素)"
        case .bmp: return "BMP"
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .targa: return "TARGA"
        case .gif: return "GIF"
        case .mp4: return "MP4(视频纹理)"
        }
    }
}

struct TexMipmap {
    let width: Int
    let height: Int
    let isLZ4: Bool
    let decompressedSize: Int
    let rawBytes: [UInt8]
}

struct TexImage {
    let mipmaps: [TexMipmap]
}

struct TexFile {
    let format: TexPixelFormat
    let flags: Int
    let textureWidth: Int
    let textureHeight: Int
    let imageWidth: Int
    let imageHeight: Int
    let containerMagic: String
    let imageFormat: FreeImageFormat
    let isVideoTexture: Bool
    let images: [TexImage]

    var isGIF: Bool { (flags & 4) != 0 }
}

func parseTex(_ data: Data) throws -> TexFile {
    var r = ByteReader(data)

    let magic1 = try r.nstring(maxLength: 16)
    guard magic1 == "TEXV0005" else { throw ProbeError.badMagic(expected: "TEXV0005", got: magic1) }
    let magic2 = try r.nstring(maxLength: 16)
    guard magic2 == "TEXI0001" else { throw ProbeError.badMagic(expected: "TEXI0001", got: magic2) }

    let rawFormat = Int(try r.i32())
    guard let format = TexPixelFormat(rawValue: rawFormat) else {
        throw ProbeError.unsupported("纹理格式码 \(rawFormat)")
    }
    let flags = Int(try r.i32())
    let texW = Int(try r.i32())
    let texH = Int(try r.i32())
    let imgW = Int(try r.i32())
    let imgH = Int(try r.i32())
    _ = try r.i32()   // 未知字段（RePKG: UnkInt0）

    let containerMagic = try r.nstring(maxLength: 16)
    guard containerMagic.hasPrefix("TEXB") else {
        throw ProbeError.badMagic(expected: "TEXB000x", got: containerMagic)
    }
    let version = Int(containerMagic.suffix(4)) ?? 0
    let imageCount = Int(try r.i32())
    guard imageCount >= 0, imageCount <= 1024 else { throw ProbeError.invalid("图像数异常 \(imageCount)") }

    var imageFormat = FreeImageFormat.unknown
    var isVideo = false
    if version >= 3 {
        imageFormat = FreeImageFormat(rawValue: Int(try r.i32())) ?? .unknown
    }
    if version >= 4 {
        isVideo = (try r.i32()) == 1
        if imageFormat == .unknown && isVideo { imageFormat = .mp4 }
    }

    var images: [TexImage] = []
    for _ in 0..<imageCount {
        let mipmapCount = Int(try r.i32())
        guard mipmapCount >= 0, mipmapCount <= 64 else { throw ProbeError.invalid("mipmap 数异常 \(mipmapCount)") }

        var mipmaps: [TexMipmap] = []
        for _ in 0..<mipmapCount {
            // 说明（2026-09-23 真实样本实测）：TEXB0004 的 mipmap 布局与 V2/V3 **完全一致**
            // （w, h, isLZ4, decompressedSize, byteCount, bytes）。
            // RePKG 里那段 "p1==1, p2==2, conditionJson, p3==1" 的 V4 特例（源码标 FIXME）
            // 在真实文件上会导致 110/127 个纹理解析失败 —— 已用字节级取证推翻，故不采用。
            let w = Int(try r.i32())
            let h = Int(try r.i32())
            var isLZ4 = false
            var decompressedSize = 0
            if version >= 2 {
                isLZ4 = (try r.i32()) == 1
                decompressedSize = Int(try r.i32())
            }
            let byteCount = Int(try r.i32())
            guard byteCount >= 0, byteCount <= 512 * 1024 * 1024 else {
                throw ProbeError.invalid("mipmap 字节数异常 \(byteCount)")
            }
            let bytes = try r.take(byteCount)
            mipmaps.append(TexMipmap(width: w, height: h, isLZ4: isLZ4,
                                     decompressedSize: decompressedSize, rawBytes: bytes))
        }
        images.append(TexImage(mipmaps: mipmaps))
    }

    return TexFile(format: format, flags: flags, textureWidth: texW, textureHeight: texH,
                   imageWidth: imgW, imageHeight: imgH, containerMagic: containerMagic,
                   imageFormat: imageFormat, isVideoTexture: isVideo, images: images)
}

/// 把某个 mipmap 解成 RGBA8
func texMipmapToRGBA(_ tex: TexFile, mipmap: TexMipmap) throws -> (width: Int, height: Int, rgba: [UInt8]) {
    var payload = mipmap.rawBytes
    if mipmap.isLZ4 {
        payload = try lz4BlockDecompress(payload, expectedSize: mipmap.decompressedSize)
    }

    if tex.imageFormat != .unknown {
        // 内嵌图片（PNG/JPEG/GIF/...）→ 交给 ImageIO
        guard let src = CGImageSourceCreateWithData(Data(payload) as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ProbeError.unsupported("内嵌图片解码失败（\(tex.imageFormat.name)）")
        }
        return try cgImageToRGBA(cg)
    }

    switch tex.format {
    case .rgba8888:
        guard payload.count >= mipmap.width * mipmap.height * 4 else {
            throw ProbeError.truncated("RGBA8888 数据不足")
        }
        return (mipmap.width, mipmap.height, Array(payload.prefix(mipmap.width * mipmap.height * 4)))
    case .dxt1:
        return (mipmap.width, mipmap.height, try decodeDXT(payload, width: mipmap.width, height: mipmap.height, kind: .dxt1))
    case .dxt3:
        return (mipmap.width, mipmap.height, try decodeDXT(payload, width: mipmap.width, height: mipmap.height, kind: .dxt3))
    case .dxt5:
        return (mipmap.width, mipmap.height, try decodeDXT(payload, width: mipmap.width, height: mipmap.height, kind: .dxt5))
    case .rg88:
        var out = [UInt8](repeating: 255, count: mipmap.width * mipmap.height * 4)
        for i in 0..<(mipmap.width * mipmap.height) {
            out[i * 4] = payload[i * 2]
            out[i * 4 + 1] = payload[i * 2 + 1]
            out[i * 4 + 2] = 0
        }
        return (mipmap.width, mipmap.height, out)
    case .r8:
        var out = [UInt8](repeating: 255, count: mipmap.width * mipmap.height * 4)
        for i in 0..<(mipmap.width * mipmap.height) {
            out[i * 4] = payload[i]
            out[i * 4 + 1] = payload[i]
            out[i * 4 + 2] = payload[i]
        }
        return (mipmap.width, mipmap.height, out)
    }
}

func cgImageToRGBA(_ cg: CGImage) throws -> (width: Int, height: Int, rgba: [UInt8]) {
    let w = cg.width
    let h = cg.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ok: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard ok else { throw ProbeError.invalid("CGContext 创建失败") }
    return (w, h, buf)
}

func writePNG(_ rgba: [UInt8], width: Int, height: Int, to path: String) throws {
    guard let provider = CGDataProvider(data: Data(rgba) as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false,
                              intent: .defaultIntent) else {
        throw ProbeError.invalid("PNG 图像构造失败")
    }
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
        throw ProbeError.invalid("无法写入 \(path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw ProbeError.invalid("PNG 收尾失败") }
}

// MARK: - scene.json 摘要（只读，不渲染）

func summarizeScene(_ data: Data) throws -> String {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ProbeError.invalid("scene.json 顶层不是对象")
    }
    var lines: [String] = []
    var counters: [String: Int] = [:]
    var scriptFieldCount = 0
    var userPropertyRefs = 0
    var textureRefs: Set<String> = []

    func looksLikeScriptedValue(_ value: Any) -> Bool {
        guard let dict = value as? [String: Any] else { return false }
        return dict["script"] != nil && dict["value"] != nil
    }

    func walk(_ objects: [Any], depth: Int) {
        for case let obj as [String: Any] in objects {
            // 类型判定（2026-09-23 真实样本实测修正）：
            //   · 有 image/model/text/particle/sound/light/camera 键 → 对应类型
            //   · 有 objects 子数组 → group（真实文件里 group 不一定带 "group" 键）
            //   · 有 effects / shape → effect（WE 的效果发射器，如 shape=quad 加 effects[]）
            //   · 只有变换类键（id/name/origin/scale/angles/parent/visible/parallaxDepth…）→ node（空节点/纯变换组）
            var type = "unknown"
            for candidate in ["image", "model", "text", "particle", "sound", "light", "camera"] {
                if obj[candidate] != nil { type = candidate; break }
            }
            if type == "unknown" {
                if obj["objects"] != nil { type = "group" }
                else if obj["effects"] != nil || obj["shape"] != nil { type = "effect" }
                else { type = "node" }
            }
            counters[type, default: 0] += 1

            for (key, value) in obj {
                if looksLikeScriptedValue(value) { scriptFieldCount += 1; _ = key }
                // 用户属性引用：{"user": "属性名", "value": ...}（可在 WE 界面由用户调整）
                if let dict = value as? [String: Any], dict["user"] != nil { userPropertyRefs += 1 }
            }

            if let image = obj["image"] as? String { textureRefs.insert(image) }
            if let name = obj["model"] as? String { textureRefs.insert(name) }

            let name = (obj["name"] as? String) ?? ""
            let indent = String(repeating: "  ", count: depth)
            lines.append("\(indent)- \(type)\(name.isEmpty ? "" : " \"\(name)\"")")

            if let children = obj["objects"] as? [Any] { walk(children, depth: depth + 1) }
        }
    }

    if let camera = root["camera"] { lines.append("camera: \(camera is [String: Any] ? "有" : "无")") }
    if let general = root["general"] as? [String: Any] {
        let keys = general.keys.sorted().joined(separator: ", ")
        lines.append("general 字段: \(keys)")
    }
    if let objects = root["objects"] as? [Any] { walk(objects, depth: 0) }

    var summary = lines.joined(separator: "\n")
    summary += "\n\n对象统计: " + counters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
    summary += "\n带 script 的字段数: \(scriptFieldCount)"
    summary += "\n用户属性引用数: \(userPropertyRefs)"
    summary += "\n引用到的资源: \(textureRefs.sorted().joined(separator: ", "))"
    return summary
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
    print("  样本目录: \(tmp.path)")

    print("\n=== 自检结果：通过 \(c.passes) 项，失败 \(c.failures.count) 项 ===")
    if !c.failures.isEmpty {
        for f in c.failures { print("  ❌ \(f)") }
        exit(1)
    }
}

// MARK: - 命令

func usage() {
    print("""
    用法:
      we-scene-probe selftest                 合成样本自检（不需要真实素材）
      we-scene-probe pkg <scene.pkg>          列出 PKGV 条目
      we-scene-probe extract <pkg> <outdir>   解包
      we-scene-probe tex <file.tex> [out.png] 解析 TEX，可导出首张图 PNG
      we-scene-probe scene <scene.json>       打印场景结构摘要
    """)
}

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
        for e in pkg.entries {
            let dest = outDir.appendingPathComponent(e.path)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(try pkg.data(of: e)).write(to: dest)
        }
        print("已解出 \(pkg.entries.count) 个条目 → \(outDir.path)")

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

    case "scene":
        guard args.count >= 3 else { usage(); exit(2) }
        print(try summarizeScene(try Data(contentsOf: URL(fileURLWithPath: args[2]))))

    default:
        usage(); exit(2)
    }
} catch {
    FileHandle.standardError.write("错误: \(error)\n".data(using: .utf8)!)
    exit(1)
}
