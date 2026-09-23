import Foundation
import CryptoKit

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
      we-scene-probe capabilities <scene.pkg> [max-edge]  输出受限预览与桌面播放能力边界 JSON
      we-scene-probe catalog <directory> [max-edge]  只读发现一级子目录中的scene.pkg及其能力
      we-scene-probe still <scene.pkg> <out.png> [max-edge]  导出静态基础图及同名 .json 诊断
      we-scene-probe frame <scene.pkg> <materials/name.tex> <seconds> <out.png> [max-edge]  离线视频纹理取帧并合成
      we-scene-probe sequence <scene.pkg> <materials/name.tex> <fps> <count> <outdir> [max-edge]  有界离线逐帧序列，非实时播放
      we-scene-probe realtime-probe <scene.pkg> <materials/name.tex> <seconds> [poll-hz]  静音无窗口视频输出采样，不控制桌面
      we-scene-probe realtime-scene-probe <scene.pkg> <materials/name.tex> <seconds> <outdir> [poll-hz] [max-edge]  无窗口受限scene合成
      we-scene-probe transport-probe <scene.pkg> <materials/name.tex>  静音无窗口验证暂停/恢复/显式回绕
      we-scene-probe loop-probe <scene.pkg> <materials/name.tex>  静音无窗口验证轮询驱动的自动片尾循环
      we-scene-probe stability-probe <scene.pkg> <materials/name.tex> <seconds> [poll-hz] [max-edge]  有界无窗口合成统计
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

    case "capabilities":
        guard (3...4).contains(args.count) else { usage(); exit(2) }
        let maxEdge = args.count == 4 ? (Int(args[3]) ?? 0) : 640
        let data = try WESceneInspection.capabilityReport(
            packageData: Data(contentsOf: URL(fileURLWithPath: args[2])), maxPreviewDimension: maxEdge)
        print(String(decoding: data, as: UTF8.self))
        // A restricted preview is useful for inspection, but not a playable wallpaper.
        exit(3)

    case "catalog":
        guard (3...4).contains(args.count) else { usage(); exit(2) }
        let maxEdge = args.count == 4 ? (Int(args[3]) ?? 0) : 640
        let data = try WESceneInspection.catalog(
            directory: URL(fileURLWithPath: args[2], isDirectory: true), maxPreviewDimension: maxEdge)
        print(String(decoding: data, as: UTF8.self))
        exit(3) // Catalog discovery never establishes desktop scene playback.

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

    case "sequence":
        guard (7...8).contains(args.count), let fps = Double(args[4]), fps.isFinite,
              (1...60).contains(fps),
              let count = Int(args[5]), (1...120).contains(count) else { usage(); exit(2) }
        let maxEdge = args.count == 8 ? (Int(args[7]) ?? 0) : 960
        guard (1...1600).contains(maxEdge) else { throw ProbeError.invalid("离线序列最大边长必须在1...1600") }
        let destination = URL(fileURLWithPath: args[6], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ProbeError.invalid("序列输出目录必须不存在，拒绝覆盖")
        }
        let session = try await WESceneOfflineFrameSession.open(
            packageData: Data(contentsOf: URL(fileURLWithPath: args[2])), videoTexturePath: args[3])
        let timeline = try WESceneOfflineTimeline(framesPerSecond: fps, durationSeconds: session.durationSeconds)
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".wescene-sequence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        var frames: [[String: Any]] = []
        for index in 0..<count {
            try Task.checkCancellation()
            let seconds = try timeline.sourceSeconds(forFrame: index)
            let image = try await session.frame(atSeconds: seconds, maxDimension: maxEdge)
            guard image.hasRenderableContent else { throw ProbeError.unsupported("序列帧没有可合成内容") }
            let name = String(format: "frame-%04d", index)
            try writePNG([UInt8](image.rgba), width: image.width, height: image.height,
                         to: staging.appendingPathComponent(name + ".png").path)
            try image.diagnosticsJSON.write(to: staging.appendingPathComponent(name + ".json"), options: .withoutOverwriting)
            let report = try JSONDecoder().decode(PreviewSummary.self, from: image.diagnosticsJSON)
            frames.append(["index": index, "requestedSeconds": seconds,
                           "actualSeconds": report.actualSeconds ?? seconds, "png": name + ".png"])
        }
        let manifest: [String: Any] = ["schemaVersion": 1, "frameMode": "offlineSequence",
                                        "playable": false, "faithful": false,
                                        "framesPerSecond": fps, "frameCount": count,
                                        "videoDurationSeconds": session.durationSeconds,
                                        "videoTexture": args[3], "frames": frames]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: staging.appendingPathComponent("sequence.json"), options: .withoutOverwriting)
        try FileManager.default.moveItem(at: staging, to: destination)
        print("离线序列: \(destination.path) (\(count)帧)；复用单个提取视频与解码器，不代表桌面连续播放")

    case "realtime-probe":
        guard (5...6).contains(args.count), let duration = Double(args[4]),
              duration.isFinite, (0.5...5).contains(duration) else { usage(); exit(2) }
        let pollHz = args.count == 6 ? (Int(args[5]) ?? 0) : 10
        guard (2...30).contains(pollHz) else { usage(); exit(2) }
        let session = try await WESceneRealtimeVideoSession.open(
            packageData: Data(contentsOf: URL(fileURLWithPath: args[2])), videoTexturePath: args[3])
        var observations: [[String: Any]] = []
        do {
            try await session.play()
            let started = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - started < duration {
                try Task.checkCancellation()
                if let frame = try await session.poll() {
                    let digest = SHA256.hash(data: frame.rgba).map { String(format: "%02x", $0) }.joined()
                    observations.append(["itemSeconds": frame.itemSeconds,
                                         "displaySeconds": frame.displaySeconds,
                                         "sha256": digest, "width": frame.width, "height": frame.height])
                }
                try await Task.sleep(nanoseconds: UInt64(1_000_000_000 / pollHz))
            }
            await session.close()
        } catch {
            await session.close()
            throw error
        }
        let distinct = Set(observations.compactMap { $0["sha256"] as? String }).count
        let report: [String: Any] = ["schemaVersion": 1, "probeMode": "windowlessMutedVideoOutput",
                                     "playableScene": false, "desktopAttached": false,
                                     "requestedDurationSeconds": duration, "pollHz": pollHz,
                                     "videoDurationSeconds": session.durationSeconds,
                                     "observedFrames": observations.count, "distinctFrames": distinct,
                                     "frames": observations]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        if distinct < 2 { exit(3) }

    case "realtime-scene-probe":
        guard (6...8).contains(args.count), let duration = Double(args[4]),
              duration.isFinite, (0.5...3).contains(duration) else { usage(); exit(2) }
        let pollHz = args.count >= 7 ? (Int(args[6]) ?? 0) : 5
        let maxEdge = args.count == 8 ? (Int(args[7]) ?? 0) : 640
        guard (2...10).contains(pollHz), (1...960).contains(maxEdge) else { usage(); exit(2) }
        let destination = URL(fileURLWithPath: args[5], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ProbeError.invalid("无窗口合成输出目录必须不存在，拒绝覆盖")
        }
        let session = try await WESceneRealtimeSceneSession.open(
            packageData: Data(contentsOf: URL(fileURLWithPath: args[2])), videoTexturePath: args[3])
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".wescene-realtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        var observations: [[String: Any]] = []
        var cacheBeforeClose: WESceneTextureCacheStats?
        var cacheAfterClose: WESceneTextureCacheStats?
        do {
            try await session.play()
            let started = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - started < duration && observations.count < 20 {
                try Task.checkCancellation()
                if let frame = try await session.poll(maxDimension: maxEdge) {
                    guard frame.preview.hasRenderableContent else {
                        throw ProbeError.unsupported("无窗口scene帧没有可合成图层")
                    }
                    let name = String(format: "frame-%04d", observations.count)
                    try writePNG([UInt8](frame.preview.rgba), width: frame.preview.width,
                                 height: frame.preview.height,
                                 to: staging.appendingPathComponent(name + ".png").path)
                    try frame.preview.diagnosticsJSON.write(
                        to: staging.appendingPathComponent(name + ".json"), options: .withoutOverwriting)
                    let digest = SHA256.hash(data: frame.preview.rgba).map { String(format: "%02x", $0) }.joined()
                    observations.append(["itemSeconds": frame.itemSeconds,
                                         "displaySeconds": frame.displaySeconds,
                                         "sha256": digest, "png": name + ".png"])
                }
                try await Task.sleep(nanoseconds: UInt64(1_000_000_000 / pollHz))
            }
            cacheBeforeClose = await session.cacheStats()
            await session.close()
            cacheAfterClose = await session.cacheStats()
        } catch {
            await session.close()
            throw error
        }
        let distinct = Set(observations.compactMap { $0["sha256"] as? String }).count
        let manifest: [String: Any] = ["schemaVersion": 1, "frameMode": "windowlessRealtimeProbe",
                                        "playableScene": false, "faithful": false, "desktopAttached": false,
                                        "requestedDurationSeconds": duration, "pollHz": pollHz,
                                        "observedFrames": observations.count, "distinctFrames": distinct,
                                        "videoTexture": args[3], "frames": observations,
                                        "staticTextureCache": [
                                            "hits": cacheBeforeClose?.hits ?? 0,
                                            "misses": cacheBeforeClose?.misses ?? 0,
                                            "residentBytesBeforeClose": cacheBeforeClose?.residentBytes ?? 0,
                                            "residentBytesAfterClose": cacheAfterClose?.residentBytes ?? -1
                                        ]]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: staging.appendingPathComponent("probe.json"), options: .withoutOverwriting)
        try FileManager.default.moveItem(at: staging, to: destination)
        print("无窗口受限scene帧: \(destination.path) (\(observations.count)帧，\(distinct)种画面)；非桌面播放")
        if distinct < 2 { exit(3) }

    case "transport-probe":
        guard args.count == 4 else { usage(); exit(2) }
        let session = try await WESceneRealtimeVideoSession.open(
            packageData: Data(contentsOf: URL(fileURLWithPath: args[2])), videoTexturePath: args[3])
        guard session.durationSeconds > 3 else { throw ProbeError.unsupported("传输探针要求视频时长超过3秒") }
        func collect(_ seconds: Double) async throws -> [[String: Any]] {
            let started = ProcessInfo.processInfo.systemUptime
            var items: [[String: Any]] = []
            while ProcessInfo.processInfo.systemUptime - started < seconds {
                try Task.checkCancellation()
                if let frame = try await session.poll() {
                    let digest = SHA256.hash(data: frame.rgba).map { String(format: "%02x", $0) }.joined()
                    items.append(["displaySeconds": frame.displaySeconds, "sha256": digest])
                }
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            return items
        }
        var first: [[String: Any]] = [], resumed: [[String: Any]] = []
        var nearEnd: [[String: Any]] = [], restarted: [[String: Any]] = []
        var pausedAt = 0.0, pausedAfterWait = 0.0
        var invalidSeekRejected = false
        do {
            do { try await session.seek(to: -1) }
            catch { invalidSeekRejected = true }
            try await session.play()
            first = try await collect(1.0)
            await session.pause()
            pausedAt = await session.currentSeconds()
            try await Task.sleep(nanoseconds: 600_000_000)
            pausedAfterWait = await session.currentSeconds()
            try await session.play()
            resumed = try await collect(0.8)
            await session.pause()
            try await session.seek(to: session.durationSeconds - 0.5)
            try await session.play()
            nearEnd = try await collect(0.8)
            try await session.restart()
            restarted = try await collect(0.8)
            await session.close()
        } catch {
            await session.close()
            throw error
        }
        let report: [String: Any] = ["schemaVersion": 1, "probeMode": "mutedWindowlessTransport",
                                     "desktopAttached": false, "playableScene": false,
                                     "videoDurationSeconds": session.durationSeconds,
                                     "pausedAtSeconds": pausedAt, "pausedAfterWaitSeconds": pausedAfterWait,
                                     "pauseDriftSeconds": abs(pausedAfterWait - pausedAt),
                                     "invalidSeekRejected": invalidSeekRejected,
                                     "initial": first, "resumed": resumed,
                                     "nearEnd": nearEnd, "restarted": restarted]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        let nearEndSeen = nearEnd.contains { ($0["displaySeconds"] as? Double ?? 0) > session.durationSeconds - 1 }
        let restartSeen = restarted.contains { ($0["displaySeconds"] as? Double ?? .infinity) < 2 }
        if first.isEmpty || resumed.isEmpty || !nearEndSeen || !restartSeen ||
            !invalidSeekRejected || abs(pausedAfterWait - pausedAt) > 0.05 { exit(3) }

    case "loop-probe":
        guard args.count == 4 else { usage(); exit(2) }
        let session = try await WESceneRealtimeVideoSession.open(
            packageData: Data(contentsOf: URL(fileURLWithPath: args[2])), videoTexturePath: args[3])
        guard session.durationSeconds > 3 else { throw ProbeError.unsupported("循环探针要求视频时长超过3秒") }
        var observations: [[String: Any]] = []
        var loops = 0, loopsAfterPause = 0
        do {
            try await session.setLooping(true)
            try await session.seek(to: session.durationSeconds - 0.5)
            try await session.play()
            let started = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - started < 1.6 {
                try Task.checkCancellation()
                if let frame = try await session.poll() {
                    let digest = SHA256.hash(data: frame.rgba).map { String(format: "%02x", $0) }.joined()
                    observations.append(["displaySeconds": frame.displaySeconds, "sha256": digest])
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            loops = await session.completedLoops()
            await session.pause()
            try await Task.sleep(nanoseconds: 300_000_000)
            _ = try await session.poll()
            loopsAfterPause = await session.completedLoops()
            await session.close()
        } catch {
            await session.close()
            throw error
        }
        let nearEndSeen = observations.contains { ($0["displaySeconds"] as? Double ?? 0) > session.durationSeconds - 1 }
        let restartSeen = observations.contains { ($0["displaySeconds"] as? Double ?? .infinity) < 1 }
        let report: [String: Any] = ["schemaVersion": 1, "probeMode": "pollDrivenAutoLoop",
                                     "desktopAttached": false, "playableScene": false,
                                     "videoDurationSeconds": session.durationSeconds,
                                     "completedLoops": loops, "completedLoopsAfterPause": loopsAfterPause,
                                     "nearEndSeen": nearEndSeen, "restartSeen": restartSeen,
                                     "frames": observations]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        if loops != 1 || loopsAfterPause != loops || !nearEndSeen || !restartSeen { exit(3) }

    case "stability-probe":
        guard (5...7).contains(args.count), let duration = Double(args[4]),
              duration.isFinite, (3...15).contains(duration) else { usage(); exit(2) }
        let pollHz = args.count >= 6 ? (Int(args[5]) ?? 0) : 5
        let maxEdge = args.count == 7 ? (Int(args[6]) ?? 0) : 640
        guard (2...10).contains(pollHz), (1...960).contains(maxEdge) else { usage(); exit(2) }
        let session = try await WESceneRealtimeSceneSession.open(
            packageData: Data(contentsOf: URL(fileURLWithPath: args[2])), videoTexturePath: args[3])
        var pollAttempts = 0, observedFrames = 0, loops = 0
        var displayTimes: [Double] = [], processingSeconds: [Double] = [], hashes: Set<String> = []
        var cacheBefore: WESceneTextureCacheStats?, cacheAfter: WESceneTextureCacheStats?
        do {
            try await session.setLooping(true)
            let sourceDuration = await session.videoDurationSeconds()
            guard sourceDuration > 2.1 else { throw ProbeError.unsupported("持续探针要求视频时长超过2.1秒") }
            try await session.seek(to: sourceDuration - 2)
            try await session.play()
            let started = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - started < duration {
                try Task.checkCancellation()
                pollAttempts += 1
                let before = ProcessInfo.processInfo.systemUptime
                if let frame = try await session.poll(maxDimension: maxEdge) {
                    observedFrames += 1
                    displayTimes.append(frame.displaySeconds)
                    hashes.insert(SHA256.hash(data: frame.preview.rgba).map { String(format: "%02x", $0) }.joined())
                    processingSeconds.append(ProcessInfo.processInfo.systemUptime - before)
                }
                try await Task.sleep(nanoseconds: UInt64(1_000_000_000 / pollHz))
            }
            loops = await session.completedLoops()
            cacheBefore = await session.cacheStats()
            await session.close()
            cacheAfter = await session.cacheStats()
        } catch {
            await session.close()
            throw error
        }
        let sortedProcessing = processingSeconds.sorted()
        let p95Index = max(0, Int(ceil(Double(sortedProcessing.count) * 0.95)) - 1)
        let maximumGap = zip(displayTimes, displayTimes.dropFirst()).map { current, next in
            next >= current ? next - current : 0 // reset at loop is a separate discontinuity
        }.max() ?? 0
        let report: [String: Any] = ["schemaVersion": 1, "probeMode": "boundedWindowlessSceneStability",
                                     "desktopAttached": false, "playableScene": false,
                                     "requestedSeconds": duration, "requestedPollHz": pollHz,
                                     "pollAttempts": pollAttempts, "observedFrames": observedFrames,
                                     "distinctFrames": hashes.count, "completedLoops": loops,
                                     "maxForwardDisplayGapSeconds": maximumGap,
                                     "meanProcessingSeconds": processingSeconds.isEmpty ? 0 : processingSeconds.reduce(0,+) / Double(processingSeconds.count),
                                     "p95ProcessingSeconds": sortedProcessing.isEmpty ? 0 : sortedProcessing[p95Index],
                                     "staticTextureCache": ["hits": cacheBefore?.hits ?? 0,
                                                            "misses": cacheBefore?.misses ?? 0,
                                                            "residentBytesBeforeClose": cacheBefore?.residentBytes ?? 0,
                                                            "residentBytesAfterClose": cacheAfter?.residentBytes ?? -1],
                                     "displayTimes": displayTimes]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        if observedFrames < 5 || hashes.count < 3 || loops < 1 || cacheAfter?.residentBytes != 0 { exit(3) }

    default:
        usage(); exit(2)
    }
} catch {
    FileHandle.standardError.write("错误: \(error)\n".data(using: .utf8)!)
    exit(1)
}
}
}
