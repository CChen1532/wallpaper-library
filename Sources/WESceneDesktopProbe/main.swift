import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import WESceneCore

private enum DesktopTrialError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

private enum TrialRasterImage {
    static func make(width: Int, height: Int, rgba: Data) throws -> NSImage {
        guard (1...640).contains(width), (1...640).contains(height),
              rgba.count == width * height * 4,
              let provider = CGDataProvider(data: rgba as CFData),
              let image = CGImage(width: width, height: height,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent) else {
            throw DesktopTrialError.invalid("桌面试验帧的 RGBA 像素无效")
        }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }

    static func selfTest() throws {
        let pixels = Data([255, 0, 0, 255, 0, 255, 0, 255,
                           0, 0, 255, 255, 255, 255, 255, 128])
        let image = try make(width: 2, height: 2, rgba: pixels)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw DesktopTrialError.invalid("桌面试验测试图像无法生成")
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let red = bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB),
              let green = bitmap.colorAt(x: 1, y: 0)?.usingColorSpace(.deviceRGB),
              let blue = bitmap.colorAt(x: 0, y: 1)?.usingColorSpace(.deviceRGB),
              let half = bitmap.colorAt(x: 1, y: 1)?.usingColorSpace(.deviceRGB),
              red.redComponent > 0.98, green.greenComponent > 0.98,
              blue.blueComponent > 0.98, abs(half.alphaComponent - 0.5) < 0.02,
              (try? make(width: 2, height: 2, rgba: Data([0]))) == nil,
              (try? make(width: 641, height: 1, rgba: Data(repeating: 0, count: 641 * 4))) == nil else {
            throw DesktopTrialError.invalid("RGBA颜色、方向、透明度或边界自检失败")
        }
    }
}

/// Snapshot rather than a retained NSScreen: a topology change invalidates the trial.
private struct TrialDisplaySnapshot: Equatable {
    let id: UInt32
    let frame: NSRect

    init(id: UInt32, frame: NSRect) throws {
        guard id != 0, frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0,
              frame.width <= 32_768, frame.height <= 32_768 else {
            throw DesktopTrialError.invalid("试验显示器信息无效")
        }
        self.id = id
        self.frame = frame
    }

    static func capture(_ screen: NSScreen) throws -> TrialDisplaySnapshot {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw DesktopTrialError.invalid("无法识别试验显示器")
        }
        return try TrialDisplaySnapshot(id: number.uint32Value, frame: screen.frame)
    }

    func matches(_ screen: NSScreen) -> Bool {
        guard let other = try? TrialDisplaySnapshot.capture(screen) else { return false }
        return self == other
    }
}

/// This gate is one-shot. The actual source and sink are closed by WESceneFrameDelivery.
private final class TrialLifecycle {
    private enum State { case idle, running, stopping, closed }
    private var state: State = .idle

    func start() throws {
        guard state == .idle else { throw DesktopTrialError.invalid("桌面试验不能重复启动") }
        state = .running
    }

    func requestStop() -> Bool {
        guard state == .running else { return false }
        state = .stopping
        return true
    }

    func finish() -> Bool {
        guard state != .closed else { return false }
        state = .closed
        return true
    }

    static func selfTest() throws {
        let good = try TrialDisplaySnapshot(id: 7, frame: NSRect(x: -100, y: 0, width: 1920, height: 1080))
        guard good == (try TrialDisplaySnapshot(id: 7, frame: good.frame)),
              good != (try TrialDisplaySnapshot(id: 8, frame: good.frame)),
              good != (try TrialDisplaySnapshot(id: 7, frame: NSRect(x: -100, y: 0, width: 1280, height: 720))) else {
            throw DesktopTrialError.invalid("显示器快照比较失败")
        }
        for bad in [NSRect(x: 0, y: 0, width: 0, height: 10),
                    NSRect(x: 0, y: 0, width: CGFloat.nan, height: 10),
                    NSRect(x: 0, y: 0, width: 32_769, height: 10)] {
            guard (try? TrialDisplaySnapshot(id: 7, frame: bad)) == nil else {
                throw DesktopTrialError.invalid("非法显示器尺寸未被拒绝")
            }
        }
        guard (try? TrialDisplaySnapshot(id: 0, frame: good.frame)) == nil else {
            throw DesktopTrialError.invalid("无效显示器标识未被拒绝")
        }
        let gate = TrialLifecycle()
        try gate.start()
        guard gate.requestStop(), !gate.requestStop(), gate.finish(), !gate.finish(),
              (try? gate.start()) == nil else {
            throw DesktopTrialError.invalid("试验生命周期未保持一次性停止/清理")
        }
        print("桌面试验显示器快照、非法几何与一次性停止自检通过；未创建窗口")
    }
}

/// Developer-only desktop-level surface. Creating it does not prove desktop visibility.
@MainActor private final class DesktopTrialSurface {
    private var window: NSWindow?
    private let imageView = NSImageView()

    init(screen: NSScreen, snapshot: TrialDisplaySnapshot) throws {
        guard snapshot.matches(screen) else {
            throw DesktopTrialError.invalid("创建显示面前显示器已变化")
        }
        let window = NSWindow(contentRect: snapshot.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false, screen: screen)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.backgroundColor = .black
        window.isOpaque = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = NSRect(origin: .zero, size: snapshot.frame.size)
        window.contentView = imageView
        self.window = window
        window.orderFrontRegardless()
    }

    func present(_ frame: WESceneRealtimeSceneFrame) throws {
        let preview = frame.preview
        guard window != nil else { throw DesktopTrialError.invalid("桌面试验显示面已关闭") }
        imageView.image = try TrialRasterImage.make(width: preview.width,
                                                    height: preview.height,
                                                    rgba: preview.rgba)
    }

    func close() {
        imageView.image = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
    }
}

@MainActor private final class DesktopTrialSink: WESceneFrameSink {
    private var surface: DesktopTrialSurface?
    private var digests: Set<Data> = []
    private(set) var delivered = 0
    var distinctFrames: Int { digests.count }

    init(surface: DesktopTrialSurface) { self.surface = surface }

    func accept(_ frame: WESceneRealtimeSceneFrame) throws {
        guard let surface else { throw DesktopTrialError.invalid("试验显示面已拆除") }
        try surface.present(frame)
        digests.insert(Data(SHA256.hash(data: frame.preview.rgba)))
        delivered += 1
    }

    func finish() {
        surface?.close()
        surface = nil
    }
}

@MainActor private final class DesktopProbeController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var controlWindow: NSWindow?
    private let packageLabel = NSTextField(labelWithString: "尚未选择场景包")
    private let textureField = NSTextField()
    private let displayPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let startButton = NSButton(title: "开始 5 秒桌面试验", target: nil, action: nil)
    private let stopButton = NSButton(title: "停止并清理", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "隔离开发试验；不是正式 Scene 壁纸")
    private var displayIDs: [UInt32] = []
    private var packageURL: URL?
    private var work: Task<Void, Never>?
    private var delivery: WESceneFrameDelivery?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let lifecycle = TrialLifecycle()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Scene 桌面试验控制 · 最多 5 秒"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        controlWindow = window

        let chooseButton = NSButton(title: "选择 scene.pkg", target: self, action: #selector(choosePackage))
        let row = NSStackView(views: [chooseButton, packageLabel])
        row.orientation = .horizontal
        row.spacing = 12
        textureField.placeholderString = "包内视频纹理路径，例如 materials/name.tex"
        displayPopup.setAccessibilityLabel("试验显示器")
        populateDisplays()
        startButton.target = self
        startButton.action = #selector(startTrial)
        startButton.isEnabled = false
        stopButton.target = self
        stopButton.action = #selector(stopFromButton)
        stopButton.isEnabled = false
        statusLabel.textColor = .secondaryLabelColor

        let note = NSTextField(labelWithString: "会短时覆盖所选桌面背景；不修改系统壁纸或 phonto。未经当次许可勿启动。")
        note.lineBreakMode = .byWordWrapping
        let actions = NSStackView(views: [startButton, stopButton])
        actions.orientation = .horizontal
        actions.spacing = 12
        let stack = NSStackView(views: [note, row, textureField, displayPopup, actions, statusLabel])
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
                textureField.widthAnchor.constraint(equalTo: stack.widthAnchor),
                displayPopup.widthAnchor.constraint(equalTo: stack.widthAnchor)
            ])
        }
        observeEnvironment()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func populateDisplays() {
        let previous = displayPopup.indexOfSelectedItem
        displayPopup.removeAllItems()
        displayIDs = NSScreen.screens.compactMap { screen in
            guard let snapshot = try? TrialDisplaySnapshot.capture(screen) else { return nil }
            displayPopup.addItem(withTitle: "\(screen.localizedName) · \(snapshot.id)")
            return snapshot.id
        }
        if displayIDs.indices.contains(previous) { displayPopup.selectItem(at: previous) }
        startButton.isEnabled = packageURL != nil && !displayIDs.isEmpty && work == nil
    }

    private func observeEnvironment() {
        let appCenter = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for (center, name) in [
            (appCenter, NSApplication.didChangeScreenParametersNotification),
            (workspaceCenter, NSWorkspace.activeSpaceDidChangeNotification),
            (workspaceCenter, NSWorkspace.willSleepNotification),
            (workspaceCenter, NSWorkspace.screensDidSleepNotification)
        ] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.environmentChanged(name.rawValue) }
            }
            observers.append((center, token))
        }
    }

    private func environmentChanged(_ reason: String) {
        if work == nil { populateDisplays(); return }
        requestStop(reason: "环境变化（\(reason)），正在停止并清理…")
    }

    @objc private func choosePackage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择单个 scene.pkg；只读加载，桌面试验最多 5 秒"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.packageURL = url
            self?.packageLabel.stringValue = url.lastPathComponent
            self?.startButton.isEnabled = !(self?.displayIDs.isEmpty ?? true)
        }
    }

    @objc private func startTrial() {
        guard work == nil, let packageURL else { return }
        let texture = textureField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !texture.isEmpty, !texture.hasPrefix("/"), !texture.contains(".."),
              !texture.contains("\\") else {
            statusLabel.stringValue = "请填写安全的包内相对 TEX 路径"
            return
        }
        let index = displayPopup.indexOfSelectedItem
        guard displayIDs.indices.contains(index),
              let screen = NSScreen.screens.first(where: {
                  (try? TrialDisplaySnapshot.capture($0).id) == displayIDs[index]
              }), let snapshot = try? TrialDisplaySnapshot.capture(screen) else {
            statusLabel.stringValue = "目标显示器已经变化，请重新选择"
            populateDisplays()
            return
        }
        do { try lifecycle.start() }
        catch { statusLabel.stringValue = error.localizedDescription; return }
        startButton.isEnabled = false
        textureField.isEnabled = false
        displayPopup.isEnabled = false
        stopButton.isEnabled = true
        statusLabel.stringValue = "正在只读加载；试验显示面建立后最多交付 5 秒…"
        work = Task { [weak self] in
            await self?.perform(packageURL: packageURL, texture: texture, snapshot: snapshot)
        }
    }

    @objc private func stopFromButton() { requestStop(reason: "用户请求停止，正在清理…") }

    private func requestStop(reason: String) {
        guard lifecycle.requestStop() else { return }
        statusLabel.stringValue = reason
        stopButton.isEnabled = false
        work?.cancel()
        if let delivery { Task { await delivery.requestStop() } }
    }

    private func perform(packageURL: URL, texture: String, snapshot: TrialDisplaySnapshot) async {
        var source: WESceneRealtimeSceneSession?
        var deliveryOwnsResources = false
        do {
            let scoped = packageURL.startAccessingSecurityScopedResource()
            defer { if scoped { packageURL.stopAccessingSecurityScopedResource() } }
            let values = try packageURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= 64 * 1024 * 1024 else {
                throw DesktopTrialError.invalid("仅接受不超过 64 MiB 的非链接 scene.pkg")
            }
            let data = try Data(contentsOf: packageURL, options: .mappedIfSafe)
            guard data.count == size else { throw DesktopTrialError.invalid("读取期间场景包大小变化") }
            try Task.checkCancellation()
            let opened = try await WESceneRealtimeSceneSession.open(packageData: data, videoTexturePath: texture)
            source = opened
            try Task.checkCancellation()
            guard let screen = NSScreen.screens.first(where: { snapshot.matches($0) }) else {
                throw DesktopTrialError.invalid("显示器布局变化，试验未启动")
            }
            let limits = try WESceneFrameDeliveryLimits(durationSeconds: 5, pollHz: 10,
                                                        maxDimension: 640, maxFrames: 50)
            let surface = try DesktopTrialSurface(screen: screen, snapshot: snapshot)
            let sink = DesktopTrialSink(surface: surface)
            let delivery = WESceneFrameDelivery(source: opened, sink: sink, limits: limits)
            self.delivery = delivery
            deliveryOwnsResources = true
            let summary = try await delivery.run()
            self.delivery = nil
            try Task.checkCancellation()
            guard summary.deliveredFrames >= 2, sink.distinctFrames >= 2 else {
                throw DesktopTrialError.invalid("试验未取得足够不同画面；不能视为桌面动态验收")
            }
            print("隔离桌面试验交付 \(summary.deliveredFrames) 帧、\(sink.distinctFrames) 种画面；还需人工桌面验收")
            finish(exitCode: 0)
        } catch {
            self.delivery = nil
            if !deliveryOwnsResources { await source?.close() }
            FileHandle.standardError.write("隔离桌面试验失败：\(error)\n".data(using: .utf8)!)
            statusLabel.stringValue = "试验已停止：\(error.localizedDescription)；未更改系统壁纸"
            try? await Task.sleep(for: .seconds(1))
            finish(exitCode: 1)
        }
    }

    func windowWillClose(_ notification: Notification) {
        if work == nil { finish(exitCode: 0) }
        else { requestStop(reason: "控制窗口关闭，正在清理桌面试验…") }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard work != nil else { return .terminateNow }
        requestStop(reason: "应用退出请求，正在清理桌面试验…")
        return .terminateCancel
    }

    private func finish(exitCode: Int32) {
        guard lifecycle.finish() else { return }
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        controlWindow?.delegate = nil
        controlWindow?.close()
        controlWindow = nil
        Darwin.exit(exitCode)
    }
}

@main private enum WESceneDesktopProbeMain {
    static func main() {
        if CommandLine.arguments == [CommandLine.arguments[0], "--selftest"] {
            do {
                try TrialLifecycle.selfTest()
                try TrialRasterImage.selfTest()
                print("桌面试验RGBA颜色、方向、透明度与边界自检通过；未创建窗口")
                return
            }
            catch { FileHandle.standardError.write("\(error)\n".data(using: .utf8)!); Darwin.exit(1) }
        }
        guard CommandLine.arguments == [CommandLine.arguments[0], "--desktop-trial"] else {
            FileHandle.standardError.write("桌面试验默认禁用；必须显式传入 --desktop-trial，且运行前取得用户当次许可。\n".data(using: .utf8)!)
            Darwin.exit(2)
        }
        let app = NSApplication.shared
        let controller = DesktopProbeController()
        app.delegate = controller
        app.setActivationPolicy(.regular)
        withExtendedLifetime(controller) { app.run() }
    }
}
