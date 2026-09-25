import Foundation
import CoreGraphics
import ImageIO

enum CoverSource: Hashable, Sendable {
    case scene(URL?)
    case video(URL?)
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

    init() {
        cache.countLimit = 64
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(for source: CoverSource) -> CoverRaster? {
        for url in candidates(for: source) {
            // URL resource values can stay cached after the file changes. Read
            // fresh attributes before deciding whether a decoded raster is current.
            guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
                  values[.type] as? FileAttributeType == .typeRegular,
                  let size = values[.size] as? Int, size > 0, size <= 16 * 1024 * 1024 else { continue }
            let modified = (values[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let key = "\(url.standardizedFileURL.path)|\(size)|\(modified)" as NSString
            if let cached = cache.object(forKey: key) { return cached }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: 960
                  ] as CFDictionary) else { continue }
            let result = CoverRaster(image)
            cache.setObject(result, forKey: key, cost: image.bytesPerRow * image.height)
            return result
        }
        return nil
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
