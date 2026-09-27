import AppKit

@MainActor enum MoonPreview {
    private static var process: Process?
    private static var observer: NSObjectProtocol?
    static func open(assets: URL) {
        if let process, process.isRunning {
            NSRunningApplication(processIdentifier: process.processIdentifier)?.activate(options: [])
            return
        }
        guard let executable = Bundle.main.resourceURL?.appendingPathComponent("MoonSceneRenderer") else { return }
        let child = Process(); child.executableURL = executable
        child.arguments = ["--preview", "--assets", assets.path]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        do {
            try child.run(); process = child
            if observer == nil {
                observer = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { if let process, process.isRunning { process.terminate() } }
                }
            }
        } catch {
            let alert = NSAlert(error: error); alert.runModal()
        }
    }
}
