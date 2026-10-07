import Foundation
import CoreGraphics
import ImageIO

enum CoverSource: Hashable, Sendable {
    case scene(URL?)
    case video(URL?)
    case videoProject(folder: URL, fallback: URL?)
    case remote(URL?)
}

enum CoverSize: Int, Sendable {
    case card = 512
    case inspector = 960
    case hero = 2560
}

struct CoverRequest: Hashable, Sendable {
    let source: CoverSource
    let size: CoverSize
}

/// Immutable, downsampled frames; animation never decodes on the UI actor.
final class CoverRaster: @unchecked Sendable {
    let frames: [CGImage]
    let frameEnds: [TimeInterval]
    var image: CGImage { frames[0] }
    var duration: TimeInterval { frameEnds.last ?? 0 }
    var cost: Int { frames.reduce(0) { $0 + $1.bytesPerRow * $1.height } }
    init(_ image: CGImage) { frames = [image]; frameEnds = [0] }
    init(frames: [CGImage], delays: [TimeInterval]) {
        self.frames = frames
        var elapsed = 0.0
        frameEnds = delays.map { elapsed += $0; return elapsed }
    }
    func frameIndex(at elapsed: TimeInterval) -> Int {
        guard frames.count > 1, duration > 0, elapsed.isFinite else { return 0 }
        let time = max(0, elapsed).truncatingRemainder(dividingBy: duration)
        return min(frames.count - 1, frameEnds.firstIndex(where: { time < $0 }) ?? 0)
    }
}

actor CoverImageLoader {
    static let shared = CoverImageLoader()
    private let cache = NSCache<NSString, CoverRaster>()
    private let decodeQueue = OperationQueue()
    private var pending: [String: Task<CoverRaster?, Never>] = [:]
    private var remoteData: [URL: (Date, Data)] = [:]
    private var remotePending: [URL: Task<Data?, Never>] = [:]
    private var remoteFailures: [URL: Date] = [:]
    private var networkCount = 0
    private var networkWaiters: [CheckedContinuation<Void, Never>] = []
    static let maximumBytes = 16 * 1024 * 1024
    static let animationBudget = 12 * 1024 * 1024

    init() {
        cache.countLimit = 64
        cache.totalCostLimit = 128 * 1024 * 1024
        decodeQueue.maxConcurrentOperationCount = 2
        decodeQueue.qualityOfService = .userInitiated
    }

    func image(for source: CoverSource, size requestedSize: CoverSize = .inspector,
               animated: Bool = false) async -> CoverRaster? {
        guard !Task.isCancelled else { return nil }
        if case .remote(let url) = source {
            guard let url, Self.allowedRemote(url) else { return nil }
            let key = "remote|\(url.absoluteString)|\(requestedSize.rawValue)|\(animated)"
            if let cached = cache.object(forKey: key as NSString) { return cached }
            let result = await coalesced(key) {
                guard let data = await self.download(url) else { return nil }
                return await self.decode(data: data, size: requestedSize, animated: animated)
            }
            return Task.isCancelled ? nil : result
        }
        for url in candidates(for: source) {
            guard !Task.isCancelled else { return nil }
            guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
                  values[.type] as? FileAttributeType == .typeRegular,
                  let size = values[.size] as? Int, size > 0, size <= Self.maximumBytes else { continue }
            let modified = (values[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            // Atomic replacement can preserve both size and modification time.
            let fileIdentity = "\(values[.systemNumber] ?? 0)|\(values[.systemFileNumber] ?? 0)"
            let key = "\(url.standardizedFileURL.path)|\(fileIdentity)|\(size)|\(modified)|\(requestedSize.rawValue)|\(animated)"
            if let cached = cache.object(forKey: key as NSString) { return cached }
            let result = await coalesced(key) {
                await self.decode(url: url, size: requestedSize, animated: animated)
            }
            guard !Task.isCancelled else { return nil }
            if let result { return result }
        }
        return nil
    }

    private func coalesced(_ key: String, load: @escaping @Sendable () async -> CoverRaster?) async -> CoverRaster? {
        if let task = pending[key] { return await task.value }
        let task = Task { await load() }
        pending[key] = task
        let result = await task.value
        pending[key] = nil
        if let result { cache.setObject(result, forKey: key as NSString, cost: result.cost) }
        return result
    }

    private func decode(url: URL? = nil, data: Data? = nil, size: CoverSize, animated: Bool) async -> CoverRaster? {
        await withCheckedContinuation { continuation in
            decodeQueue.addOperation {
                let options = [kCGImageSourceShouldCache: false] as CFDictionary
                let source = url.map { CGImageSourceCreateWithURL($0 as CFURL, options) }
                    ?? data.map { CGImageSourceCreateWithData($0 as CFData, options) }
                continuation.resume(returning: source.flatMap { $0 }.flatMap {
                    Self.decodeFrames($0, size: size.rawValue, animated: animated)
                })
            }
        }
    }

    static func decodeFrames(_ source: CGImageSource, size: Int, animated: Bool) -> CoverRaster? {
        let count = CGImageSourceGetCount(source)
        guard count > 0, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16384, height <= 16384,
              width * height <= 64 * 1024 * 1024 else { return nil }
        let type = CGImageSourceGetType(source) as String? ?? ""
        // Multi-page TIFF/PDF files are not animations.
        let isAnimation = animated && count > 1 && count <= 1000
            && ["com.compuserve.gif", "public.png", "org.webmproject.webp"].contains(type)
        let outputCount = isAnimation ? min(count, 96) : 1
        var pixelLimit = isAnimation
            ? min(size, 320, Int(sqrt(Double(animationBudget / outputCount / 4)))) : size
        // ImageIO may align scanlines; include row padding in the decoded budget.
        if isAnimation {
            while outputCount * ((pixelLimit * 4 + 63) / 64 * 64) * pixelLimit > animationBudget {
                pixelLimit -= 1
            }
        }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceShouldCacheImmediately: true,
                       kCGImageSourceThumbnailMaxPixelSize: pixelLimit] as CFDictionary
        var frames: [CGImage] = [], delays: [TimeInterval] = []
        var decodedCost = 0
        for slot in 0..<outputCount {
            let index = isAnimation ? slot * count / outputCount : 0
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options) else {
                return frames.first.map(CoverRaster.init)
            }
            decodedCost += image.bytesPerRow * image.height
            if isAnimation && decodedCost > animationBudget { return frames.first.map(CoverRaster.init) }
            frames.append(image)
            if isAnimation {
                let end = (slot + 1) * count / outputCount
                delays.append((index..<end).reduce(0) { $0 + frameDelay(source, index: $1) })
            } else { delays.append(0) }
        }
        return CoverRaster(frames: frames, delays: delays)
    }

    private static func frameDelay(_ source: CGImageSource, index: Int) -> TimeInterval {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let formats: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime)
        ]
        for (key, unclamped, clamped) in formats {
            if let dictionary = properties[key] as? [CFString: Any],
               let value = (dictionary[unclamped] ?? dictionary[clamped]) as? Double,
               value.isFinite, value > 0 { return max(0.02, value) }
        }
        return 0.1
    }

    private func candidates(for source: CoverSource) -> [URL] {
        switch source {
        case .video(let url): return url.map { [$0] } ?? []
        case .remote: return []
        case .videoProject(let folder, let fallback):
            // Only treat a video's directory as a project if it declares one.
            let project = folder.appendingPathComponent("project.json")
            let previews = FileManager.default.fileExists(atPath: project.path) ? candidates(for: .scene(folder)) : []
            return previews + (fallback.map { [$0] } ?? [])
        case .scene(let folder):
            guard let folder else { return [] }
            var names = ["preview.gif", "preview.webp", "preview.apng", "preview.jpg", "preview.png"]
            let project = folder.appendingPathComponent("project.json")
            if let values = try? project.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
               values.isSymbolicLink != true, let size = values.fileSize, size <= 1_048_576,
               let data = try? Data(contentsOf: project),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = object["preview"] as? String { names.insert(name, at: 0) }
            return names.filter { !$0.isEmpty && !$0.contains("/") && !$0.contains("\\") && $0 != "." && $0 != ".." }
                .map { folder.appendingPathComponent($0) }
        }
    }

    static func allowedRemote(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased(), url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return ["steamusercontent.com", "steamuserimages-a.akamaihd.net", "steamstatic.com"].contains {
            host == $0 || host.hasSuffix("." + $0)
        }
    }

    private func download(_ url: URL) async -> Data? {
        if let cached = remoteData[url], Date().timeIntervalSince(cached.0) < 300 { return cached.1 }
        if let failed = remoteFailures[url], Date().timeIntervalSince(failed) < 30 { return nil }
        if let task = remotePending[url] { return await task.value }
        let task = Task { () -> Data? in
            await self.acquireNetwork()
            let data = await Self.fetch(url)
            self.releaseNetwork()
            return data
        }
        remotePending[url] = task
        let data = await task.value
        remotePending[url] = nil
        if let data {
            if remoteData.values.reduce(0, { $0 + $1.1.count }) + data.count > 32 * 1024 * 1024 { remoteData.removeAll() }
            remoteData[url] = (Date(), data)
        } else {
            if remoteFailures.count > 256 { remoteFailures.removeAll() }
            remoteFailures[url] = Date()
        }
        return data
    }
    private func acquireNetwork() async {
        if networkCount < 4 { networkCount += 1; return }
        await withCheckedContinuation { networkWaiters.append($0) }
    }
    private func releaseNetwork() {
        if networkWaiters.isEmpty { networkCount -= 1 }
        else { networkWaiters.removeFirst().resume() }
    }
    private static func fetch(_ url: URL) async -> Data? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let finalURL = http.url, allowedRemote(finalURL), response.expectedContentLength <= maximumBytes else { return nil }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumBytes else { return nil }
                data.append(byte)
            }
            return data
        } catch { return nil }
    }
}
