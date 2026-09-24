import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import WESceneCore

private enum VisibleProbeError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

/// Top-down, straight-alpha RGBA supplied by the restricted scene compositor.
private enum FrameRasterImage {
    static func make(width: Int, height: Int, rgba: Data) throws -> NSImage {
        guard (1...640).contains(width), (1...640).contains(height),
              rgba.count == width * height * 4,
              let provider = CGDataProvider(data: rgba as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else {
            throw VisibleProbeError.invalid("RGBA帧尺寸或像素缓冲无效")
        }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }

    static func selfTest() throws {
        let pixels = Data([255, 0, 0, 255, 0, 255, 0, 255,
                           0, 0, 255, 255, 255, 255, 255, 128])
        let image = try make(width: 2, height: 2, rgba: pixels)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw VisibleProbeError.invalid("测试图像无法生成CGImage")
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        func matches(_ x: Int, _ y: Int, _ expected: (Double, Double, Double, Double)) -> Bool {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            let actual = (color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent)
            return abs(actual.0 - expected.0) < 0.02 && abs(actual.1 - expected.1) < 0.02 &&
                   abs(actual.2 - expected.2) < 0.02 && abs(actual.3 - expected.3) < 0.02
        }
        guard matches(0, 0, (1, 0, 0, 1)), matches(1, 0, (0, 1, 0, 1)),
              matches(0, 1, (0, 0, 1, 1)), matches(1, 1, (1, 1, 1, 0.5)) else {
            throw VisibleProbeError.invalid("RGBA颜色、方向或透明度测试失败")
        }
        let shortBufferRejected: Bool
        do { _ = try make(width: 2, height: 2, rgba: Data([0])); shortBufferRejected = false }
        catch { shortBufferRejected = true }
        let oversizeRejected: Bool
        do { _ = try make(width: 641, height: 1, rgba: Data(repeating: 0, count: 641 * 4)); oversizeRejected = false }
        catch { oversizeRejected = true }
        guard shortBufferRejected, oversizeRejected else {
            throw VisibleProbeError.invalid("RGBA无效尺寸或缓冲未被拒绝")
        }
        print("RGBA颜色、方向、透明度与边界自检通过")
    }
}

@MainActor private final class VisibleFrameSink: WESceneFrameSink {
    private weak var imageView: NSImageView?
    private(set) var delivered = 0
    private var digests: Set<Data> = []
    private(set) var finished = false
    var distinctFrames: Int { digests.count }

    init(imageView: NSImageView) { self.imageView = imageView }

    func accept(_ frame: WESceneRealtimeSceneFrame) throws {
        guard !finished, let imageView else {
            throw VisibleProbeError.invalid("实验窗口已关闭")
        }
        imageView.image = try FrameRasterImage.make(width: frame.preview.width,
                                                     height: frame.preview.height,
                                                     rgba: frame.preview.rgba)
        digests.insert(Data(SHA256.hash(data: frame.preview.rgba)))
        delivered += 1
    }

    func finish() {
        finished = true
        imageView = nil
    }
}

@MainActor private final class VisibleProbeController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private let imageView = NSImageView()
    private let packageLabel = NSTextField(labelWithString: "尚未选择场景包")
    private let textureField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "仅限开发验收；不是桌面动态壁纸")
    private let startButton = NSButton(title: "开始 5 秒实验画面", target: nil, action: nil)
    private var packageURL: URL?
    private var work: Task<Void, Never>?
    private var delivery: WESceneFrameDelivery?
    private var finishing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Scene 实验画面 · 非桌面壁纸"
        window.level = .normal
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window

        let chooseButton = NSButton(title: "选择 scene.pkg", target: self, action: #selector(choosePackage))
        startButton.target = self
        startButton.action = #selector(startProbe)
        startButton.isEnabled = false
        textureField.placeholderString = "包内视频纹理路径，例如 materials/name.tex"

        let row = NSStackView(views: [chooseButton, packageLabel])
        row.orientation = .horizontal
        row.spacing = 12
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.cgColor
        imageView.heightAnchor.constraint(greaterThanOrEqualToConstant: 430).isActive = true
        statusLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            NSTextField(labelWithString: "受限 Scene 动态画面测试（画面交付最多 5 秒；不会改变桌面壁纸）"),
            row, textureField, startButton, imageView, statusLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
                imageView.widthAnchor.constraint(equalTo: stack.widthAnchor)
            ])
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func choosePackage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择单个 scene.pkg；只读加载，不修改原素材或桌面"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.packageURL = url
            self?.packageLabel.stringValue = url.lastPathComponent
            self?.startButton.isEnabled = true
        }
    }

    @objc private func startProbe() {
        guard work == nil, let packageURL else { return }
        let texture = textureField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !texture.isEmpty, !texture.hasPrefix("/"), !texture.contains(".."),
              !texture.contains("\\") else {
            statusLabel.stringValue = "请填写安全的包内相对 TEX 路径"
            return
        }
        startButton.isEnabled = false
        textureField.isEnabled = false
        statusLabel.stringValue = "正在只读加载并显示短时实验画面…"
        work = Task { [weak self] in await self?.perform(packageURL: packageURL, texture: texture) }
    }

    private func perform(packageURL: URL, texture: String) async {
        do {
            let scoped = packageURL.startAccessingSecurityScopedResource()
            defer { if scoped { packageURL.stopAccessingSecurityScopedResource() } }
            let values = try packageURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= 64 * 1024 * 1024 else {
                throw VisibleProbeError.invalid("仅接受不超过 64 MiB 的非链接 scene.pkg")
            }
            let data = try Data(contentsOf: packageURL, options: .mappedIfSafe)
            guard data.count == size else { throw VisibleProbeError.invalid("读取期间场景包大小变化") }
            try Task.checkCancellation()
            let session = try await WESceneRealtimeSceneSession.open(packageData: data,
                                                                      videoTexturePath: texture)
            do {
                try Task.checkCancellation()
                let sink = VisibleFrameSink(imageView: imageView)
                let limits = try WESceneFrameDeliveryLimits(durationSeconds: 5, pollHz: 10,
                                                            maxDimension: 640, maxFrames: 50)
                let delivery = WESceneFrameDelivery(source: session, sink: sink, limits: limits)
                self.delivery = delivery
                let summary = try await delivery.run()
                self.delivery = nil
                guard summary.deliveredFrames >= 2, sink.distinctFrames >= 2 else {
                    throw VisibleProbeError.invalid("短时实验未取得足够的不同画面；不能视为动态播放验收")
                }
                print("实验窗口交付 \(summary.deliveredFrames) 帧，\(sink.distinctFrames) 种画面；原因 \(summary.stopReason.rawValue)；非桌面播放")
                finish(exitCode: 0)
            } catch {
                await session.close()
                throw error
            }
        } catch {
            FileHandle.standardError.write("Scene 实验窗口失败：\(error)\n".data(using: .utf8)!)
            statusLabel.stringValue = "实验失败：\(error.localizedDescription)；未更改桌面壁纸"
            try? await Task.sleep(for: .seconds(1))
            finish(exitCode: 1)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard !finishing else { return }
        work?.cancel()
        if let delivery { Task { await delivery.requestStop() } }
        if work == nil { finish(exitCode: 0) }
    }

    private func finish(exitCode: Int32) {
        guard !finishing else { return }
        finishing = true
        delivery = nil
        window?.delegate = nil
        window?.close()
        window = nil
        Darwin.exit(exitCode)
    }
}

@main private enum WESceneVisibleProbeMain {
    static func main() {
        if CommandLine.arguments == [CommandLine.arguments[0], "--selftest"] {
            do { try FrameRasterImage.selfTest(); return }
            catch { FileHandle.standardError.write("\(error)\n".data(using: .utf8)!); Darwin.exit(1) }
        }
        guard CommandLine.arguments.count == 1 else {
            FileHandle.standardError.write("此开发测试应用不接受包路径参数；请在窗口内手动选择。\n".data(using: .utf8)!)
            Darwin.exit(2)
        }
        let app = NSApplication.shared
        let controller = VisibleProbeController()
        app.delegate = controller
        app.setActivationPolicy(.regular)
        withExtendedLifetime(controller) { app.run() }
    }
}
