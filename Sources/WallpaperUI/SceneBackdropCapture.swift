import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Only accepts pixels exported by the owned renderer. No desktop screenshot,
/// library cover or previous wallpaper is used as a fallback.
enum SceneBackdropCapture {
    static func capture(package: URL, state: URL, render: (URL) throws -> Void) throws -> URL {
        let identity = package.standardizedFileURL.resolvingSymlinksInPath().path
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = state.appendingPathComponent("Captures/" + key, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let raw = directory.appendingPathComponent("renderer.heic")
        let image = directory.appendingPathComponent("wallpaper.png")
        defer { try? FileManager.default.removeItem(at: raw) }
        do {
            try render(raw)
            guard let source = CGImageSourceCreateWithURL(raw as CFURL, nil),
                  let pixels = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  pixels.width > 0, pixels.height > 0,
                  let destination = CGImageDestinationCreateWithURL(image as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw BackendError.message("当前壁纸截图无法解码，未应用底图")
            }
            CGImageDestinationAddImage(destination, pixels, nil)
            guard CGImageDestinationFinalize(destination),
                  let check = CGImageSourceCreateWithURL(image as CFURL, nil),
                  CGImageSourceGetType(check) as String? == UTType.png.identifier else {
                throw BackendError.message("当前壁纸截图转换失败，未应用底图")
            }
            let metadata: [String: Any] = ["package": identity, "image": image.path,
                                          "width": pixels.width, "height": pixels.height,
                                          "capturedAt": Date().timeIntervalSince1970]
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("source.json"), options: .atomic)
            return image
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
