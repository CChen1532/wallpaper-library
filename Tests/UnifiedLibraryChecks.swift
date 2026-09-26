import Foundation

actor InventoryCounter {
    var reads = 0
    var sideEffects = 0
    func read() { reads += 1 }
    func effect() { sideEffects += 1 }
}
struct InventoryBackend: WallpaperBackend {
    let counter: InventoryCounter
    var capabilities: BackendCapabilities { .init(name: "fixture") }
    func library() async throws -> [Wallpaper] { await counter.read(); return [Wallpaper(url: URL(fileURLWithPath: "/fixture/kept.mp4"))] }
    func state() async throws -> PlaybackState { await counter.effect(); return .init() }
    func perform(_ action: Action) async throws { await counter.effect() }
    func importFiles(_ urls: [URL]) async -> [String] { [] }
    func trash(_ url: URL) async throws {}
    func diagnostics() async throws -> BackendDiagnostics { .init(displays: "", status: "") }
}
@main struct UnifiedLibraryChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("UnifiedLibrary-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func scene(_ name: String) throws {
            let dir = root.appendingPathComponent(name)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{\"format\":\"wallpaperui.gravity.v1\",\"preset\":\"efficient\"}".utf8).write(to: dir.appendingPathComponent("scene.pkg"))
            try Data("{\"type\":\"scene\",\"title\":\"Same title\"}".utf8).write(to: dir.appendingPathComponent("project.json"))
        }
        var checks = 0
        func check(_ ok: Bool, _ label: String) { precondition(ok, label); checks += 1; print("PASS: " + label); fflush(stdout) }
        try scene("one")
        let counter = InventoryCounter()
        let model = LibraryModel(backend: InventoryBackend(counter: counter), backdropConfiguration: { nil })
        let catalog = UnifiedLibrary(model: model, roots: { [root, root] })
        let start = ContinuousClock.now
        catalog.start(); catalog.start()
        while catalog.lastScan == nil && start.duration(to: .now) < .seconds(15) { try await Task.sleep(for: .milliseconds(100)) }
        check(catalog.scenes.count == 1, "启动自动识别场景，重叠根目录去重")
        check(await counter.reads == 1, "重复start不创建多个定时器")
        model.selected = "/fixture/kept.mp4"
        try scene("two")
        while catalog.scenes.count < 2 && start.duration(to: .now) < .seconds(70) { try await Task.sleep(for: .milliseconds(200)) }
        let elapsed = start.duration(to: .now)
        check(catalog.scenes.count == 2 && elapsed >= .seconds(59), "真实60秒周期自动发现新增场景，无手动刷新")
        check(Set(catalog.scenes.map(\.id)).count == 2, "同名场景以完整路径独立标识")
        check(model.selected == "/fixture/kept.mp4", "自动检查保留选中视频")
        check(await counter.sideEffects == 0, "发现素材不调用播放或状态副作用")
        catalog.stop()
        let oldReads = await counter.reads
        try await Task.sleep(for: .seconds(1))
        check(await counter.reads == oldReads, "停止调度不重复扫描")
        try Data([0,1]).write(to: root.appendingPathComponent("two/scene.pkg"))
        await catalog.refresh()
        check(catalog.scenes.count == 1 && !catalog.issues.isEmpty, "损坏场景隔离并报告，下次仍可重试")
        try scene("two")
        await catalog.refresh()
        check(catalog.scenes.count == 2, "修复不完整包后自动识别逻辑可恢复")
        print("\(checks) unified library checks passed")
    }
}
