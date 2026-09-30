import Foundation

@main struct DisplayPlaybackChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ result: Bool, _ title: String) {
            precondition(result, title); count += 1; print("PASS: \(title)")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("display-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "display-check-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let collection = LibraryCollectionStore(defaults: defaults)
        let a = SceneDisplay(id: 1, uuid: UUID().uuidString, name: "A")
        let b = SceneDisplay(id: 2, uuid: UUID().uuidString, name: "B")
        let topology = Topology([a,b])
        let backends = [a.uuid: DisplayBackend(), b.uuid: DisplayBackend()]
        let inventory = LibraryModel(backend: DisplayBackend(), collection: collection, backdropConfiguration: { nil })
        let playback = DisplayPlayback(library: inventory, displayProvider: { topology.displays }, makeSession: { display in
            LibraryModel(backend: backends[display.uuid]!,
                scenePlayer: ScenePlayer(pinnedDisplayUUID: display.uuid, displayProvider: { topology.displays }),
                targetDisplayUUID: display.uuid, collection: collection, backdropConfiguration: { nil })
        }, recover: { true })
        await playback.start()
        let first = playback.sessions[a.uuid]!, second = playback.sessions[b.uuid]!
        let video = root.appendingPathComponent("同一视频.mp4")
        try Data([0]).write(to: video)
        inventory.items = [Wallpaper(url: video)]
        check(first.items == inventory.items && second.items == inventory.items, "one inventory is shared across both sessions")
        await first.perform(.play(video.path))
        playback.selectedUUID = b.uuid
        await second.perform(.play(video.path))
        check(first.state.running && second.state.running, "same video plays independently on both displays")
        await second.perform(.off)
        check(first.state.running && !second.state.running, "stop selected display leaves the other playing")
        let script = root.appendingPathComponent("renderer.sh")
        try #"""
        printf '%s\n' '{"event":"scene-ready"}' '{"event":"first-frame-presented"}'
        while IFS= read -r command; do
          case "$command" in
            '{"cmd":"activate"}') printf '%s\n' '{"event":"activated"}' ;;
            '{"cmd":"deactivate"}') printf '%s\n' '{"event":"deactivated"}' ;;
            '{"cmd":"quit"}') exit 0 ;;
          esac
        done
        """#.write(to: script, atomically: true, encoding: .utf8)
        func configuration(_ display: SceneDisplay) -> SceneLaunchConfiguration {
            .init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [script.path], environment: nil,
                  package: root.appendingPathComponent("same/scene.pkg"), title: "same scene", displayID: display.id)
        }
        await second.playPreparedScene(configuration(b))
        try await waitUntil { second.scenePlayer.phase == .playing }
        check(first.state.running && second.scenePlayer.isActive, "video plus scene coexist")
        await first.playPreparedScene(configuration(a))
        try await waitUntil { first.scenePlayer.phase == .playing }
        check(first.scenePlayer.isActive && second.scenePlayer.isActive, "two real child-process lifecycles play the same scene independently")
        check(!first.state.running && !second.state.running, "scene switches stop only matching video owners")
        await playback.poll()
        check(first.scenePlayer.isActive && second.scenePlayer.isActive, "polling does not mistake other displays for an engine conflict")
        topology.displays = [a]
        await playback.refreshDisplays()
        check(first.scenePlayer.isActive && !second.scenePlayer.isActive && playback.selectedUUID == a.uuid,
              "disconnect stops only the missing display and selects a connected target")
        check(second.scenePlayer.preferredDisplayID() == nil, "missing pinned screen never falls back onto another owner")
        topology.displays = [a, .init(id: 12, uuid: b.uuid, name: "B")]
        await playback.refreshDisplays()
        check(playback.sessions[b.uuid] === second && second.scenePlayer.preferredDisplayID() == 12,
              "reconnect reuses UUID ownership with a new transient display ID")
        await second.playPreparedScene(configuration(b))
        check(!second.scenePlayer.isActive && second.error != nil, "stale prepared display ID is rejected")
        await second.perform(.play(video.path))
        check(first.scenePlayer.isActive && second.state.running, "reconnected display can play independently")
        try await first.stopLocalPlaybackForRemoval(root.appendingPathComponent("unrelated"))
        check(first.scenePlayer.isActive && second.state.running, "unrelated material removal preserves both owners")
        check(await inventory.prepareMaterialRemoval(root), "shared material removal prepares every display")
        check(!first.scenePlayer.isActive && !second.state.running, "shared material removal stops every affected owner")
        await first.perform(.play(video.path)); await second.perform(.play(video.path))
        await playback.stopAll()
        check(!first.state.running && !second.state.running, "all-stop clears both videos")
        let p1 = try SceneScriptStorage.prepare(package: video, root: root.appendingPathComponent("storage"), displayUUID: a.uuid)
        let p2 = try SceneScriptStorage.prepare(package: video, root: root.appendingPathComponent("storage"), displayUUID: b.uuid)
        check(p1 != p2, "same scene script storage is isolated by display")
        let one = RotationWallpaper(url: video, title: "One", kind: .video)
        let otherVideo = root.appendingPathComponent("other.mp4")
        try Data([0]).write(to: otherVideo)
        collection.addToRotation([one, RotationWallpaper(url: otherVideo, title: "Two", kind: .video)])
        first.startSelectedRotation(interval: 60, mode: "next")
        try await waitUntil { first.selectionRotation.currentID == one.id && !first.selectionRotation.switching }
        playback.selectedUUID = b.uuid
        await second.perform(.play(video.path))
        await first.perform(.next)
        try await waitUntil { first.state.currentPath == otherVideo.path && !first.selectionRotation.switching }
        check(second.state.currentPath == video.path, "rotation remains bound to its originating display after target selection changes")
        await playback.suspend()
        check(!first.selectionRotation.active && !first.state.running && !second.state.running, "sleep/session lock cleans all display owners")
        await first.perform(.play(video.path)); await second.perform(.play(video.path))
        await playback.shutdown()
        let finalA = await backends[a.uuid]!.state(), finalB = await backends[b.uuid]!.state()
        check(!finalA.running && !finalB.running, "quit cleans both videos even without backdrop leases")
        print("\(count) display playback checks passed")
    }
    @MainActor static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition() {
            if ContinuousClock.now > deadline { fatalError("condition timed out") }
            try await Task.sleep(for: .milliseconds(40))
        }
    }
}
@MainActor private final class Topology {
    var displays: [SceneDisplay]
    init(_ value: [SceneDisplay]) { displays = value }
}
private actor DisplayBackend: WallpaperBackend {
    nonisolated let capabilities = BackendCapabilities(name: "fixture", canTrash: true)
    var value = PlaybackState()
    func library() async throws -> [Wallpaper] { [] }
    func state() async -> PlaybackState { value }
    func perform(_ action: Action) async throws {
        switch action {
        case .play(let path): value = PlaybackState(running: true, lastPath: path)
        case .off, .stop: value = .init()
        default: break
        }
    }
    func importFiles(_ urls: [URL]) async -> [String] { [] }
    func trash(_ url: URL) async throws {}
    func diagnostics() async throws -> BackendDiagnostics { .init(displays: "", status: "") }
}
