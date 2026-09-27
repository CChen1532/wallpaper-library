import AppKit
import WebKit
import UniformTypeIdentifiers

func event(_ name: String, _ fields: [String: Any] = [:]) {
    var object = fields; object["event"] = name
    if let data = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys) {
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
func argument(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

/// All code is owned and bundled. The only scene-supplied resource is a GLB model.
final class LocalResources: NSObject, WKURLSchemeHandler {
    let web: URL
    let assets: URL
    init(web: URL, assets: URL) { self.web = web; self.assets = assets }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        do {
            guard let url = task.request.url, url.host == "local" else { throw CocoaError(.fileReadNoPermission) }
            let path = url.path
            let file: URL
            if path == "/assets/moon.glb" { file = assets.appendingPathComponent("moon.glb") }
            else {
                file = web.appendingPathComponent(path == "/" ? "index.html" : String(path.dropFirst())).standardizedFileURL
                guard file.resolvingSymlinksInPath().path.hasPrefix(web.resolvingSymlinksInPath().path + "/") else { throw CocoaError(.fileReadNoPermission) }
            }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            let type = ["html":"text/html", "js":"application/javascript", "css":"text/css", "glb":"model/gltf-binary"][file.pathExtension] ?? "application/octet-stream"
            task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: type.hasPrefix("text") ? "utf-8" : nil))
            task.didReceive(data); task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class App: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var window: NSWindow!
    var web: WKWebView!
    var control: DispatchSourceRead?
    var pending = Data()
    var pointerTimer: Timer?
    var scrollMonitor: Any?
    var previousPoint = NSPoint.zero
    var previousLeft = false
    var ready = false
    let preview = CommandLine.arguments.contains("--preview")
    let mouseEnabled = !CommandLine.arguments.contains("--no-mouse")
    let buttonsEnabled = !CommandLine.arguments.contains("--no-mouse-buttons")
    func screen(_ id: UInt32) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundle = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("WallpaperUI_MoonSceneRenderer.bundle")
        let resources = (Bundle(url: bundle) ?? Bundle.module).resourceURL!.appendingPathComponent("Web")
        guard let assets = argument("--assets"), FileManager.default.fileExists(atPath: assets + "/moon.glb") else {
            event("error", ["message":"NASA 月球地形模型缺失"]); NSApp.terminate(nil); return
        }
        let targetID = UInt32(argument("--display-id") ?? "0") ?? 0
        guard let target = screen(targetID) ?? (targetID == 0 ? NSScreen.main : nil) else { event("error", ["message":"Display unavailable"]); NSApp.terminate(nil); return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(LocalResources(web: resources, assets: URL(fileURLWithPath: assets)), forURLScheme: "moon")
        configuration.userContentController.add(self, name: "scene")
        configuration.userContentController.addUserScript(WKUserScript(source: "window.addEventListener('error',e=>window.webkit.messageHandlers.scene.postMessage({event:'error',message:e.message}));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        let size = NSSize(width: Double(argument("--width") ?? "1280") ?? 1280, height: Double(argument("--height") ?? "800") ?? 800)
        window = NSWindow(contentRect: preview ? NSRect(origin: NSPoint(x: 120, y: 120), size: size) : target.frame,
                          styleMask: preview ? [.titled, .closable, .miniaturizable, .resizable] : .borderless, backing: .buffered, defer: false)
        window.title = "SELENE · 月下观测台"; window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 480); window.backgroundColor = .black
        window.ignoresMouseEvents = !preview; window.contentView = web
        if !preview {
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        }
        window.alphaValue = CommandLine.arguments.contains("--deferred-show") ? 0 : 1
        if preview { window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        else { window.orderFrontRegardless() }
        web.load(URLRequest(url: URL(string: "moon://local/index.html")!))
        if CommandLine.arguments.contains("--control-stdin") { startControl() }
        if !preview && mouseEnabled {
            pointerTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30, repeats: true) { [weak self] _ in self?.pointer() }
            scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                guard let self, self.ready, self.buttonsEnabled, self.desktopGesture(), self.window.frame.contains(NSEvent.mouseLocation) else { return }
                self.js(["cmd":"scroll", "delta": e.scrollingDeltaY * 8])
            }
        }
        if let value = argument("--duration"), let duration = Double(value), duration > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { NSApp.terminate(nil) }
        }
        let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出月球预览", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu; NSApp.mainMenu = menu
    }
    func desktopGesture() -> Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate) && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    }
    func pointer() {
        guard ready else { return }
        let p = NSEvent.mouseLocation, bounds = window.frame
        let left = CGEventSource.buttonState(.combinedSessionState, button: .left)
        defer { previousPoint = p; previousLeft = left }
        guard bounds.contains(p) else { return }
        let allow = buttonsEnabled && desktopGesture()
        let dx = p.x - previousPoint.x, dy = previousPoint.y - p.y
        guard allow && left && previousLeft && abs(dx) + abs(dy) > 0.1 else { return }
        js(["cmd":"pointer", "drag":true, "dx":dx, "dy":dy])
    }
    func js(_ object: [String: Any], completion: ((Any?, Error?) -> Void)? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.sceneControl?.(\(json))", completionHandler: completion)
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let data = message.body as? [String: Any], let name = data["event"] as? String else { return }
        event(name, data)
        if name == "scene-ready" { ready = true; if !preview { js(["cmd":"desktop"]) } }
        if name == "first-frame-presented", let output = argument("--export") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.snapshot(output, token: "export", exitAfter: true) }
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.scheme == "moon" && action.request.url?.host == "local" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { event("error", ["message":error.localizedDescription]) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { event("error", ["message":"Moon WebKit process terminated"]); NSApp.terminate(nil) }
    func snapshot(_ path: String, token: String, exitAfter: Bool = false) {
        let config = WKSnapshotConfiguration(); config.afterScreenUpdates = true
        web.takeSnapshot(with: config) { image, error in
            var ok = false
            if let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                do { try png.write(to: URL(fileURLWithPath: path), options: .atomic); ok = true } catch {}
            }
            event("snapshot-done", ["token":token,"ok":ok]); if exitAfter { NSApp.terminate(nil) }
        }
    }
    func startControl() {
        let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let data = FileHandle.standardInput.availableData
            if data.isEmpty { NSApp.terminate(nil); return }
            self.pending.append(data)
            if self.pending.count > 1_048_576 { NSApp.terminate(nil); return }
            while let n = self.pending.firstIndex(of: 10) {
                let line = Data(self.pending[..<n]); self.pending.removeSubrange(...n)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { self.command(object) }
            }
        }
        control = source; source.resume()
    }
    func command(_ object: [String: Any]) {
        switch object["cmd"] as? String {
        case "activate": window.alphaValue = 1; window.orderFrontRegardless(); event("activated")
        case "deactivate": window.alphaValue = 0; event("deactivated")
        case "quit": NSApp.terminate(nil)
        case "moveDisplay":
            if let n = object["displayID"] as? NSNumber, let target = screen(n.uint32Value) {
                window.setFrame(target.frame, display: true); event("display-moved", ["display_id":n.uint32Value])
            } else { event("display-move-failed") }
        case "snapshot": if let path = object["path"] as? String, let token = object["token"] as? String { snapshot(path, token: token) }
        case "diagnostics": web.evaluateJavaScript("window.sceneDiagnostics?.()") { value, error in event("diagnostics", value as? [String: Any] ?? ["error":error?.localizedDescription ?? "not ready"]) }
        case "power", "speed", "reset", "pointer", "scroll": js(object)
        default: break
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        pointerTimer?.invalidate(); if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "scene")
        control?.cancel(); window?.orderOut(nil)
    }
}
let application = NSApplication.shared
application.setActivationPolicy(CommandLine.arguments.contains("--preview") ? .regular : .accessory)
let delegate = App(); application.delegate = delegate; application.run()
