import Foundation
import CoreGraphics
import ImageIO

@main struct CoverImageChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cover-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var count = 0
        func check(_ value: Bool, _ name: String) {
            precondition(value, "FAIL: " + name)
            count += 1; print("PASS: " + name)
        }
        func png(_ url: URL, width: Int, height: Int) throws {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            precondition(CGImageDestinationFinalize(destination))
        }
        let loader = CoverImageLoader()
        let large = root.appendingPathComponent("large.png")
        try png(large, width: 2400, height: 1200)
        let first = await loader.image(for: .video(large))!
        check(first.image.width == 960 && first.image.height == 480, "高分辨率封面缩小解码且保持比例")
        let again = await loader.image(for: .video(large))!
        check(first === again, "重复读取封面复用同一解码结果")
        let card = await loader.image(for: .video(large), size: .card)!
        check(card.image.width == 512 && card.image.height == 256, "卡片按512像素解码")
        let sameCard = await loader.image(for: .video(large), size: .card)
        check(card !== first && sameCard === card,
              "卡片与详情分别缓存且同尺寸复用")
        let parallel = root.appendingPathComponent("parallel.png")
        try FileManager.default.copyItem(at: large, to: parallel)
        let shared = await withTaskGroup(of: CoverRaster?.self, returning: [CoverRaster?].self) { group in
            for _ in 0..<12 { group.addTask { await loader.image(for: .video(parallel), size: .card) } }
            var results: [CoverRaster?] = []
            for await result in group { results.append(result) }
            return results
        }
        check(shared.count == 12 && shared.allSatisfy { $0 != nil && $0 === shared[0] },
              "并发请求同一封面复用解码结果")
        let cardBytes = card.image.bytesPerRow * card.image.height
        let detailBytes = first.image.bytesPerRow * first.image.height
        check(cardBytes < detailBytes / 3, "卡片解码内存低于原尺寸的三分之一")
        print("Decoded raster bytes: card=\(cardBytes), inspector=\(detailBytes)")
        let cancelled = Task { () -> CoverRaster? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await loader.image(for: .video(large), size: .card)
        }
        check(await cancelled.value == nil, "已经取消的封面请求直接结束")
        try png(large, width: 40, height: 20)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: large.path)
        let updated = await loader.image(for: .video(large))!
        check(updated !== first && updated.image.width == 40 && updated.image.height == 20, "同路径封面更新后不复用旧图")
        let updatedCard = await loader.image(for: .video(large), size: .card)
        check(updatedCard !== card && updatedCard?.image.width == 40, "封面更新同时使小尺寸缓存失效")
        let fallback = root.appendingPathComponent("preview.png")
        let custom = root.appendingPathComponent("custom.png")
        try png(fallback, width: 32, height: 16)
        try png(custom, width: 48, height: 24)
        let project = root.appendingPathComponent("project.json")
        try Data(#"{"preview":"custom.png"}"#.utf8).write(to: project)
        check(await loader.image(for: .scene(root))?.image.width == 48, "场景读取项目指定封面")
        try Data(#"{"preview":"../outside.png"}"#.utf8).write(to: project)
        check(await loader.image(for: .scene(root))?.image.width == 32, "非法预览路径回退到场景内封面")
        let linked = root.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: custom)
        check(await loader.image(for: .video(linked)) == nil, "拒绝链接封面")
        let broken = root.appendingPathComponent("broken.png")
        try Data("broken".utf8).write(to: broken)
        let failed = await loader.image(for: .video(broken))
        let healthy = await loader.image(for: .video(large))
        check(failed == nil && healthy === updated, "坏封面不污染已缓存图片")
        let empty = await loader.image(for: .scene(nil))
        let missing = await loader.image(for: .video(root.appendingPathComponent("missing.png")))
        check(empty == nil && missing == nil, "空路径与缺失封面返回占位状态")
        print("\(count) cover loading checks passed")
    }
}
