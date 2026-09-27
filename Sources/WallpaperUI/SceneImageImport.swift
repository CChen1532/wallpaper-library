import Foundation
import CryptoKit
import ImageIO

enum SceneImageImport {
    static func importImage(_ sourceURL: URL, for package: URL, directory: URL? = nil) throws -> URL {
        let file = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 64 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let attributes = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = attributes[kCGImagePropertyPixelWidth] as? Double,
              let height = attributes[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0, width * height <= 64_000_000 else {
            throw BackendError.message("请选择不超过 64 MB、6400 万像素的图片")
        }
        try Task.checkCancellation()
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096
        ] as CFDictionary) else { throw BackendError.message("无法读取此图片") }
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw BackendError.message("无法读取此图片")
        }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { throw BackendError.message("无法读取此图片") }
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WallpaperUI/SceneImages", isDirectory: true)
        let key = SHA256.hash(data: Data(package.standardizedFileURL.resolvingSymlinksInPath().path.utf8)).map { String(format: "%02x", $0) }.joined()
        let digest = SHA256.hash(data: data as Data).map { String(format: "%02x", $0) }.joined()
        let folder = root.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(digest + ".png")
        try Task.checkCancellation()
        if !FileManager.default.fileExists(atPath: target.path) { try (data as Data).write(to: target, options: .atomic) }
        return target
    }
}
