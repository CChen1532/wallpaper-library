import Foundation

@main struct LibraryBatchChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, "FAIL: " + message); count += 1; print("PASS: " + message)
        }
        func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
            let limit = ContinuousClock.now + .seconds(3)
            while !predicate(), ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(5)) }
            precondition(predicate(), "Timed out waiting for fixture")
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("WallpaperBatch-" + UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "WallpaperUI.BatchChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
        let a = RotationWallpaper(url: root.appendingPathComponent("A/scene.pkg"), title: "Same title", kind: .scene, expectedBytes: 3)
        let b = RotationWallpaper(url: root.appendingPathComponent("b.mp4"), title: "Same title", kind: .video)
        let c = RotationWallpaper(url: root.appendingPathComponent("c.mp4"), title: "C", kind: .video)
        let store = LibraryCollectionStore(defaults: defaults)
        check(store.hiddenIDs.isEmpty && store.rotationItems.isEmpty, "new library has no hidden items or rotation members")
        check(store.addToRotation([a,b,a,c]) == 3 && store.rotationItems == [a,b,c], "canonical IDs deduplicate without merging matching titles")
        store.setHidden(true, ids: [a.id,b.id])
        check(store.hiddenIDs == [a.id,b.id] && store.rotationCandidates == [c], "hidden members are retained but excluded from rotation")
        let reloaded = LibraryCollectionStore(defaults: defaults)
        check(reloaded.hiddenIDs == store.hiddenIDs && reloaded.rotationItems == [a,b,c], "visibility and rotation survive store recreation")
        store.setHidden(false, ids: [a.id])
        check(store.rotationCandidates == [a,c], "restore returns membership at the original list position")
        store.moveInRotation(c.id, offset: -1)
        check(store.rotationItems == [a,c,b], "rotation order can be changed")
        store.moveInRotation(a.id, offset: -1)
        check(store.rotationItems == [a,c,b], "moving beyond the list boundary does nothing")
        store.configureRotation(interval: 120, mode: "next")
        store.configureRotation(interval: 0, mode: "rand")
        check(store.interval == 120 && store.mode == "next", "invalid interval does not overwrite configuration")
        check(LibraryCollectionStore(defaults: defaults).interval == 120, "rotation timing persists without auto-starting playback")
        store.forgetRemovedTargets([a.url.deletingLastPathComponent()])
        check(store.rotationItems == [c,b] && !store.hiddenIDs.contains(a.id), "removed project metadata is cleared only under its own path")
        store.removeFromRotation(ids: [c.id,b.id])
        check(store.rotationItems.isEmpty && store.hiddenIDs == [b.id], "clearing rotation does not restore hidden files")
        check(LibraryCollectionStore.identity(URL(fileURLWithPath: "/var/tmp/a")) == LibraryCollectionStore.identity(URL(fileURLWithPath: "/private/var/tmp/a")), "equivalent macOS paths share visibility identity")

        var selection = GalleryBatchSelection()
        selection.toggle("A", visible: ["A","B","C","D"])
        selection.toggle("C", visible: ["A","B","C","D"], extend: true)
        check(selection.ids == ["A","B","C"], "Shift selection includes the complete range")
        selection.toggle("B", visible: ["A","B","C","D"])
        check(selection.ids == ["A","C"], "clicking a selected item deselects it")
        selection.retain(["C","D"])
        check(selection.ids == ["C"], "filters remove out-of-scope selections")
        selection.selectAll(["D"])
        check(selection.ids == ["D"], "select all is limited to displayed results")
        selection.toggle("A", visible: ["D"])
        check(selection.ids == ["D"], "stale cards cannot enter the selection")
        selection.clear(); check(selection.ids.isEmpty, "done selecting clears the selection")

        check(SelectionRotation.next(in: [a,b,c], currentID: c.id, direction: .next) == a, "sequential rotation wraps")
        check(SelectionRotation.next(in: [a,b,c], currentID: a.id, direction: .previous) == c, "previous wraps backwards")
        check(SelectionRotation.next(in: [a,b], currentID: a.id, direction: .random) == b, "random rotation avoids immediate repeats")
        check(SelectionRotation.next(in: [], currentID: nil, direction: .next) == nil, "empty rotation has no candidate")
        var candidates = [a,b]
        var calls: [String] = []
        var ready = true
        let rotation = SelectionRotation(items: { candidates }, ready: { ready }, play: { item in calls.append(item.id); return true }, failure: { nil })
        rotation.start(interval: 0.02, mode: "next")
        try await waitUntil { calls.count >= 3 }
        rotation.stop(); await rotation.finishPendingSwitch()
        check(Array(calls.prefix(3)) == [a.id,b.id,a.id], "scene and video descriptors use one ordered scheduler")
        let stoppedCalls = calls.count
        try await Task.sleep(for: .milliseconds(50))
        check(calls.count == stoppedCalls && !rotation.active, "stop prevents future scheduled playback")
        ready = false; rotation.start(interval: 1, mode: "next")
        check(!rotation.active, "busy backend rejects starting another rotation")
        ready = true; calls = []; candidates = [a,b]
        rotation.start(interval: 0.02, mode: "next")
        try await waitUntil { calls.count == 1 }
        candidates = [a]
        try await Task.sleep(for: .milliseconds(55))
        check(calls.count == 1, "a single remaining member is not restarted repeatedly")
        candidates = []
        try await waitUntil { !rotation.active }
        check(rotation.issue != nil, "hiding every member stops scheduling with a recoverable explanation")

        var release: CheckedContinuation<Void, Never>?
        var inFlightCalls = 0
        let pending = SelectionRotation(items: { [a,b] }, ready: { true }, play: { _ in
            inFlightCalls += 1; await withCheckedContinuation { release = $0 }; return true
        }, failure: { nil })
        pending.start(interval: 0.01, mode: "next")
        try await waitUntil { release != nil }
        pending.stop(); pending.start(interval: 0.01, mode: "next")
        check(!pending.active && pending.switching, "stop does not cancel or overlap an in-flight backend switch")
        release?.resume(); await pending.finishPendingSwitch()
        check(inFlightCalls == 1 && !pending.switching, "finishing a stopped switch does not schedule another")
        let failed = SelectionRotation(items: { [a,b] }, ready: { true }, play: { _ in false }, failure: { "fixture failure" })
        failed.start(interval: 0.01, mode: "next")
        try await waitUntil { !failed.active }
        check(failed.issue == "fixture failure", "playback failure stops rotation and preserves the reason")

        let media = root.appendingPathComponent("media")
        let trash = root.appendingPathComponent("fixture-trash")
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let first = media.appendingPathComponent("first.mp4"), second = media.appendingPathComponent("second.mp4")
        let changed = media.appendingPathComponent("changed.mp4")
        for url in [first,second,changed] { try Data([1,2,3]).write(to: url) }
        let requests = try [first,second,changed].map { try MaterialRemoval.Request(payload: $0, title: $0.lastPathComponent, roots: [media]) }
        try Data([4,5,6,7]).write(to: changed)
        let backend = BatchBackend()
        let items = [first,second].map { RotationWallpaper(url: $0, title: $0.lastPathComponent, kind: .video) }
        store.setHidden(false, ids: store.hiddenIDs); store.addToRotation(items)
        let model = LibraryModel(backend: backend, scenePreferences: ScenePreferencesStore(defaults: defaults),
            videoBackdropPreferences: VideoBackdropPreferencesStore(defaults: defaults), collection: store,
            trashItem: { url in try fm.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent)) }, backdropConfiguration: { nil })
        model.startSelectedRotation(interval: 60, mode: "next")
        try await waitUntil { model.selectionRotation.currentID == items[0].id }
        check(model.state.currentPath == first.path && model.selectionRotation.active, "selected video uses existing backend play routing")
        check(await backend.events == ["stopRotation","play"], "backend-wide rotation is disabled before selected video playback")
        await model.perform(.next)
        try await waitUntil { model.selectionRotation.currentID == items[1].id }
        check(model.state.currentPath == second.path, "next advances within the selected list")
        await model.perform(.stopRotation)
        check(!model.selectionRotation.active && model.state.currentPath == second.path, "stop rotation preserves current wallpaper")
        model.startSelectedRotation(interval: 60, mode: "next")
        try await waitUntil { model.selectionRotation.currentID == items[0].id && model.selectionRotation.active }
        await model.suspendForSystem()
        check(!model.selectionRotation.active && !model.state.running, "system sleep path stops selected rotation and playback")
        model.startSelectedRotation(interval: 60, mode: "next")
        try await waitUntil { model.selectionRotation.currentID == items[0].id && model.selectionRotation.active }
        await backend.externalStop(); await model.refreshState()
        check(!model.selectionRotation.active && model.selectionRotation.issue != nil, "external stop prevents later automatic restart")
        let result = await model.trashWallpapers(requests + [requests[0]], roots: [media])
        check(result.removed.count == 2 && result.failures.count == 1, "batch deletion deduplicates and reports partial failure")
        check(fm.fileExists(atPath: changed.path) && fm.fileExists(atPath: trash.appendingPathComponent("first.mp4").path), "changed file stays intact and successful items are recoverable")
        check(store.rotationItems.isEmpty, "successfully removed items leave the selected rotation list")
        let outside = root.appendingPathComponent("outside.mp4"); try Data([1]).write(to: outside)
        check((try? MaterialRemoval.Request(payload: outside, title: "outside", roots: [media])) == nil, "out-of-library batch target is rejected")
        try fm.moveItem(at: trash.appendingPathComponent("first.mp4"), to: first)
        try fm.moveItem(at: trash.appendingPathComponent("second.mp4"), to: second)
        store.addToRotation(items)
        model.startSelectedRotation(interval: 60, mode: "next")
        try await waitUntil { model.selectionRotation.currentID == items[0].id && model.selectionRotation.active }
        await model.shutdownScene()
        let finalState = await backend.state()
        check(!model.selectionRotation.active && !finalState.running, "application shutdown stops selected video even without a backdrop session")
        print("\(count) library batch checks passed")
    }
}

private actor BatchBackend: WallpaperBackend {
    nonisolated let capabilities = BackendCapabilities(name: "fixture", rotationModes: ["rand"], canTrash: true)
    var value = PlaybackState()
    var events: [String] = []
    func library() async throws -> [Wallpaper] { [] }
    func state() async -> PlaybackState { value }
    func externalStop() { value = .init() }
    func perform(_ action: Action) async throws {
        switch action {
        case .play(let path): events.append("play"); value.running = true; value.lastPath = path
        case .stopRotation: events.append("stopRotation"); value.rotating = false
        case .off: events.append("off"); value = .init()
        case .stop: events.append("stop"); value.running = false
        default: break
        }
    }
    func importFiles(_ urls: [URL]) async -> [String] { [] }
    func trash(_ url: URL) async throws {}
    func diagnostics() async throws -> BackendDiagnostics { .init(displays: "", status: "") }
}
