import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Samples the owned, still-hidden renderer. Some Scene packages present a
/// black title card before their first useful frame, so first-frame-presented
/// alone is not a safe point to register the system wallpaper.
enum SceneBackdropFrameSampler {
    static func openingEnabled(package: URL, values: [String: ScenePropertyValue]) -> Bool {
        ScenePropertyCatalog.load(for: package).properties.contains { property in
            guard property.kind == .boolean,
                  property.label.range(of: #"(?i)\b(intro|opening)\b|开场|片头"#,
                                       options: .regularExpression) != nil else { return false }
            return (values[property.id] ?? property.preferredDefault) == .boolean(true)
        }
    }

    static func capture(to output: URL, openingEnabled: Bool,
                        sampleTimes: [TimeInterval]? = nil,
                        snapshot: (URL) throws -> Void) throws {
        let start = ProcessInfo.processInfo.systemUptime
        let schedule = sampleTimes ?? (openingEnabled ? [0, 20, 26, 32, 38, 44] : [0, 10, 16, 22, 28, 34, 40])
        var firstWasBlank = false
        for (index, elapsed) in schedule.enumerated() {
            try Task.checkCancellation()
            // An ordinary Scene gets its first useful frame immediately. Only
            // a detected title/black frame takes the slower sampling path.
            if index > 0 && !openingEnabled && !firstWasBlank { break }
            try wait(until: start + elapsed)
            let candidate = output.deletingLastPathComponent()
                .appendingPathComponent("candidate-" + UUID().uuidString + ".heic")
            defer { try? FileManager.default.removeItem(at: candidate) }
            try snapshot(candidate)
            guard let quality = quality(of: candidate) else {
                throw BackendError.message("当前场景截图无法解码，未应用 Space 底图")
            }
            if index == 0 { firstWasBlank = quality.isNearlyBlack }
            let ready = openingEnabled ? index > 0 && quality.hasSceneContent
                                       : !firstWasBlank || index > 0 && quality.hasSceneContent
            if ready {
                try FileManager.default.moveItem(at: candidate, to: output)
                return
            }
        }
        let message = openingEnabled
            ? "场景开场仍是黑屏或标题，未覆盖系统壁纸；可关闭此壁纸的开场动画后重试"
            : "场景截图持续接近黑屏，未覆盖系统壁纸；可稍后重试"
        throw BackendError.message(message)
    }

    private static func wait(until deadline: TimeInterval) throws {
        while true {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { return }
            Thread.sleep(forTimeInterval: min(remaining, 0.1))
        }
    }

    private struct Quality {
        let isNearlyBlack: Bool
        let hasSceneContent: Bool
    }

    private static func quality(of url: URL) -> Quality? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 160,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var visible = 0, bright = 0, colored = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let r = Int(bytes[index]), g = Int(bytes[index + 1]), b = Int(bytes[index + 2])
            let highest = max(r, g, b), lowest = min(r, g, b)
            if r * 21 + g * 72 + b * 7 >= 1_000 { visible += 1 }
            if r * 21 + g * 72 + b * 7 >= 4_000 { bright += 1 }
            if highest > 30 && highest - lowest > 16 { colored += 1 }
        }
        let count = width * height
        // A few white title glyphs should not qualify as a usable still; a
        // small colorful object in a dark space scene should.
        return Quality(isNearlyBlack: visible * 1_000 < count,
                       hasSceneContent: bright * 100 >= count * 4 || colored * 1_000 >= count * 3)
    }
}

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
