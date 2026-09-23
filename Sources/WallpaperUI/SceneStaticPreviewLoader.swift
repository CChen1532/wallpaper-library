import AppKit
import CoreGraphics
import Foundation
import WESceneCore

struct SceneStaticPreviewRaster: Sendable {
    let width: Int
    let height: Int
    let rgba: Data
}

enum SceneStaticPreviewLoader {
    static let maxPackageBytes: Int64 = 64 * 1024 * 1024
    static let maxDimension = 480

    static func load(root: URL, sceneName: String, expectedBytes: Int64) throws -> SceneStaticPreviewRaster {
        guard !sceneName.isEmpty, sceneName != ".", sceneName != "..",
              !sceneName.contains("/"), !sceneName.contains("\\") else {
            throw NSError(domain: "SceneStaticPreview", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "场景目录名称无效"])
        }
        let folder = root.appendingPathComponent(sceneName, isDirectory: true)
        let package = folder.appendingPathComponent("scene.pkg", isDirectory: false)
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let folderValues = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let packageValues = try package.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
              folderValues.isDirectory == true, folderValues.isSymbolicLink != true,
              packageValues.isRegularFile == true, packageValues.isSymbolicLink != true,
              let size = packageValues.fileSize, size > 0,
              Int64(size) == expectedBytes, Int64(size) <= maxPackageBytes else {
            throw NSError(domain: "SceneStaticPreview", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "场景包已变化、是链接或超过应用内预览上限；请刷新目录"])
        }
        let data = try Data(contentsOf: package, options: .mappedIfSafe)
        guard data.count == size else {
            throw NSError(domain: "SceneStaticPreview", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "场景包读取期间发生变化；请刷新目录"])
        }
        let preview = try WESceneInspection.staticPreview(packageData: data, maxDimension: maxDimension)
        guard preview.hasRenderableContent, (1...maxDimension).contains(preview.width),
              (1...maxDimension).contains(preview.height),
              preview.rgba.count == preview.width * preview.height * 4 else {
            throw NSError(domain: "SceneStaticPreview", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "此场景没有可显示的受限静态画面"])
        }
        return SceneStaticPreviewRaster(width: preview.width, height: preview.height, rgba: preview.rgba)
    }

    @MainActor static func image(from raster: SceneStaticPreviewRaster) -> NSImage? {
        guard let provider = CGDataProvider(data: raster.rgba as CFData),
              let cgImage = CGImage(width: raster.width, height: raster.height,
                                    bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: raster.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: true,
                                    intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: raster.width, height: raster.height))
    }
}
