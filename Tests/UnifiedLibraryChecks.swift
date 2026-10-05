import Foundation

actor InventoryCounter {
    var reads = 0
    var sideEffects = 0
    private var holdNext = false
    private var readGate: CheckedContinuation<Void, Never>?
    var waiting: Bool { readGate != nil }
    func holdNextRead() { holdNext = true }
    func releaseRead() { readGate?.resume(); readGate = nil }
    func read() async {
        reads += 1
        if holdNext {
            holdNext = false
            await withCheckedContinuation { readGate = $0 }
        }
    }
    func effect() { sideEffects += 1 }
}
final class RemovalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func append(_ entry: String) { lock.withLock { entries.append(entry) } }
    var values: [String] { lock.withLock { entries } }
}
actor RemovalBackend: WallpaperBackend {
    nonisolated let capabilities: BackendCapabilities
    let video: URL
    let log: RemovalLog
    let failStop: Bool
    var active = true
    init(video: URL, log: RemovalLog, failStop: Bool = false) {
        self.video = video; self.log = log; self.failStop = failStop
        capabilities = .init(name: "fixture", libraryDirectory: video.deletingLastPathComponent(), canTrash: true)
    }
    func library() async throws -> [Wallpaper] { FileManager.default.fileExists(atPath: video.path) ? [Wallpaper(url: video)] : [] }
    func state() async throws -> PlaybackState { .init(running: active, lastPath: video.path, rotating: active) }
    func perform(_ action: Action) async throws {
        if case .off = action {
            log.append("off")
            if failStop { throw BackendError.message("fixture stop failed") }
            active = false
        }
    }
    func importFiles(_ urls: [URL]) async -> [String] { [] }
    func trash(_ url: URL) async throws { fatalError("model must coordinate restoration before trashing") }
    func diagnostics() async throws -> BackendDiagnostics { .init(displays: "", status: "") }
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
        let initial = catalog.scenes[0]
        let package = URL(fileURLWithPath: initial.packagePath)
        let originalProperties = await model.sceneUserProperties.loadCatalogInBackground(for: package)
        check(originalProperties.properties.isEmpty, "元数据更新前作者属性为空")
        try Data(#"{"type":"scene","title":"Same title","general":{"properties":{"enabled":{"type":"bool","text":"Effect","value":true}}}}"#.utf8)
            .write(to: package.deletingLastPathComponent().appendingPathComponent("project.json"), options: .atomic)
        await catalog.refresh()
        let updated = catalog.scenes[0]
        check(updated.id == initial.id, "更新作者属性保留图库和详情身份")
        check(updated.propertyCatalogRevision != initial.propertyCatalogRevision,
              "同包元数据更新必须改变侧栏属性任务修订标识")
        let refreshedProperties = await model.sceneUserProperties.loadCatalogInBackground(for: package)
        check(refreshedProperties.properties.map(\.id) == ["enabled"], "修订后重新读取获得新增作者控件")
        await catalog.refresh()
        check(catalog.scenes[0].propertyCatalogRevision == updated.propertyCatalogRevision,
              "未变化的自动扫描不重启属性加载任务")
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
        let joinedCounter = InventoryCounter()
        await joinedCounter.holdNextRead()
        let joinedModel = LibraryModel(backend: InventoryBackend(counter: joinedCounter), backdropConfiguration: { nil })
        let joinedCatalog = UnifiedLibrary(model: joinedModel, roots: { [] })
        joinedCatalog.start()
        while !(await joinedCounter.waiting) { try await Task.sleep(for: .milliseconds(10)) }
        var joinedCompleted = false
        let joining = Task { await joinedCatalog.refresh(); joinedCompleted = true }
        try await Task.sleep(for: .milliseconds(100))
        check(!joinedCompleted, "刷新调用等待在途扫描，不提前报告导入已登记")
        joinedCatalog.stop()
        await joinedCounter.releaseRead()
        await joining.value
        check(joinedCompleted && joinedCatalog.lastScan != nil && !joinedCatalog.scanning,
              "停止周期任务仍完成已承诺的在途扫描与导入登记")
        check(await joinedCounter.reads == 2, "扫描中多个请求合并为一个后续检查")

        try Data([0,1]).write(to: root.appendingPathComponent("two/scene.pkg"))
        await catalog.refresh()
        check(catalog.scenes.count == 1 && !catalog.issues.isEmpty, "损坏场景隔离并报告，下次仍可重试")
        try scene("two")
        await catalog.refresh()
        check(catalog.scenes.count == 2, "修复不完整包后自动识别逻辑可恢复")

        let suite = "UnifiedRemoval-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        MaterialDiscovery.setIncluded(true, folder: root, defaults: defaults)
        let singleCounter = InventoryCounter()
        let singleModel = LibraryModel(backend: InventoryBackend(counter: singleCounter), backdropConfiguration: { nil })
        let singleCatalog = UnifiedLibrary(model: singleModel, roots: {
            MaterialDiscovery.roots(home: root, defaults: defaults).filter { $0.path == root.path }
        }, defaults: defaults)
        singleCatalog.addFolder(root, refreshImmediately: false)
        await singleCatalog.refresh()
        check(await singleCounter.reads == 1, "导入注册和显式刷新只执行一次资料库扫描")

        let removable = UnifiedLibrary(model: model, roots: {
            MaterialDiscovery.roots(home: root, defaults: defaults).filter { $0.path == root.path }
        }, defaults: defaults)
        let scanning = Task { await removable.refresh() }
        try await Task.sleep(for: .milliseconds(100))
        await removable.removeFolder(root)
        await scanning.value
        check(removable.roots.isEmpty && removable.scenes.isEmpty, "扫描中移除来源不会重新发布旧项目")
        check(fm.fileExists(atPath: package.path), "移除来源保留实际场景文件")
        await removable.refresh()
        check(removable.scenes.isEmpty, "后续扫描不重新添加已移除来源")
        MaterialDiscovery.setIncluded(true, folder: root, defaults: defaults)
        await removable.refresh()
        check(removable.scenes.count == 2, "重新添加来源恢复已有场景")

        let video = root.appendingPathComponent("delete-fixture.mp4")
        try Data("fixture-not-a-real-video".utf8).write(to: video)
        let trash = root.appendingPathComponent("fixture-trash.mp4")
        let confirmedStamp = try MaterialDiscovery.stamp(video)
        let log = RemovalLog()
        let deletion = LibraryModel(backend: RemovalBackend(video: video, log: log), trashItem: { target in
            log.append("trash")
            try fm.moveItem(at: target, to: trash)
        }, backdropConfiguration: { nil })
        deletion.selected = video.path
        check(await deletion.trashWallpaper(payload: video, confirmedTarget: video, confirmedStamp: confirmedStamp, roots: [root]), "删除协调流程完成")
        check(log.values == ["off", "trash"], "先关闭正在播放的视频及轮播，再执行删除")
        check(deletion.selected == nil && deletion.items.isEmpty, "删除成功后清理选中项与图库")
        check(fm.fileExists(atPath: package.path), "删除独立视频不影响同目录场景")
        try fm.moveItem(at: trash, to: video)
        let failures = RemovalLog()
        let refused = LibraryModel(backend: RemovalBackend(video: video, log: failures, failStop: true), trashItem: { _ in failures.append("trash") }, backdropConfiguration: { nil })
        check(!(await refused.trashWallpaper(payload: video, confirmedTarget: video, confirmedStamp: confirmedStamp, roots: [root])), "停止失败时拒绝删除")
        check(failures.values == ["off"] && fm.fileExists(atPath: video.path), "停止失败保留原文件")
        check(!(await deletion.trashWallpaper(payload: video, confirmedTarget: root, confirmedStamp: confirmedStamp, roots: [root])), "确认目标与当前目标不符时拒绝删除")
        check(fm.fileExists(atPath: video.path), "错误确认目标不影响文件")
        try Data("replaced-since-confirmation".utf8).write(to: video)
        check(!(await deletion.trashWallpaper(payload: video, confirmedTarget: video, confirmedStamp: confirmedStamp, roots: [root])), "确认期间被替换的文件不会删除")
        print("\(checks) unified library checks passed")
    }
}
