import Foundation
import CoreGraphics
import ImageIO

enum CoverSource: Hashable, Sendable {
    case scene(URL?)
    case video(URL?)
}

enum CoverSize: Int, Sendable {
    // 240 pt cards at 2x, including the 1.045 hover zoom.
    case card = 512
    case inspector = 960
}

struct CoverRequest: Hashable, Sendable {
    let source: CoverSource
    let size: CoverSize
}

/// CGImage is immutable; only the actor owns the mutable cache.
final class CoverRaster: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// Resolving files and decoding thumbnails never run on the UI actor.
actor CoverImageLoader {
    static let shared = CoverImageLoader()
    private let cache = NSCache<NSString, CoverRaster>()
    private let decodeQueue = OperationQueue()
    private var pending: [String: Task<CoverRaster?, Never>] = [:]

    init() {
        cache.countLimit = 64
        cache.totalCostLimit = 64 * 1024 * 1024
        // A few parallel decodes fill a newly visible row quickly without
        // letting a long scroll compete with the UI for every CPU core.
        decodeQueue.maxConcurrentOperationCount = 4
        decodeQueue.qualityOfService = .userInitiated
    }

    func image(for source: CoverSource, size requestedSize: CoverSize = .inspector) async -> CoverRaster? {
        guard !Task.isCancelled else { return nil }
        for url in candidates(for: source) {
            guard !Task.isCancelled else { return nil }
            // URL resource values can stay cached after the file changes. Read
            // fresh attributes before deciding whether a decoded raster is current.
            guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
                  values[.type] as? FileAttributeType == .typeRegular,
                  let size = values[.size] as? Int, size > 0, size <= 16 * 1024 * 1024 else { continue }
            let modified = (values[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let key = "\(url.standardizedFileURL.path)|\(size)|\(modified)|\(requestedSize.rawValue)"
            if let cached = cache.object(forKey: key as NSString) { return cached }
            guard !Task.isCancelled else { return nil }
            if let pending = pending[key] {
                let result = await pending.value
                if Task.isCancelled { return nil }
                if let result { return result }
                continue
            }
            let task = Task { await decode(url, size: requestedSize) }
            pending[key] = task
            let result = await task.value
            pending[key] = nil
            if let result {
                cache.setObject(result, forKey: key as NSString,
                                cost: result.image.bytesPerRow * result.image.height)
            }
            if Task.isCancelled { return nil }
            if let result { return result }
        }
        return nil
    }

    private func decode(_ url: URL, size: CoverSize) async -> CoverRaster? {
        await withCheckedContinuation { continuation in
            decodeQueue.addOperation {
                guard let source = CGImageSourceCreateWithURL(url as CFURL,
                         [kCGImageSourceShouldCache: false] as CFDictionary),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: size.rawValue
                      ] as CFDictionary) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: CoverRaster(image))
            }
        }
    }

    private func candidates(for source: CoverSource) -> [URL] {
        switch source {
        case .video(let url): return url.map { [$0] } ?? []
        case .scene(let folder):
            guard let folder else { return [] }
            var names = ["preview.jpg", "preview.png", "preview.gif"]
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
}
