import Foundation

@main struct WorkshopEfficiencyChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("WorkshopEfficiency-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let executable = root.appendingPathComponent("steamcmd")
        try fm.copyItem(at: URL(fileURLWithPath: "Tests/Fixtures/workshop-steam-fixture.py"), to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let suite = "WorkshopEfficiency-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); count += 1; print("PASS: " + message); fflush(stdout)
        }
        func wait(_ condition: @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            precondition(condition(), "efficiency fixture deadline exceeded")
        }
        func item(_ id: String) -> WorkshopItem { .init(id: id, title: "Efficiency fixture " + id, previewURL: nil, bytes: 1, tags: ["Video"]) }
        func publishedIDs(_ library: URL) -> Set<String> {
            Set(((try? fm.contentsOfDirectory(atPath: library.path)) ?? []).filter { !$0.hasPrefix(".") })
        }
        if CommandLine.arguments.contains("--benchmark") {
            let storage = WorkshopStorage(root: root.appendingPathComponent("Benchmark"))
            var refreshes = 0
            let model = WorkshopModel(storage: storage, defaults: defaults, component: executable,
                subscriptionCache: { nil }, onImported: { _ in
                    refreshes += 1
                    try? await Task.sleep(for: .milliseconds(400))
                })
            model.account = "cached_user"
            let start = ContinuousClock.now
            for id in 1101...1105 { model.downloadFromCard(item(String(id))) }
            try await wait { !model.busy && model.pendingDownload == nil }
            let duration = start.duration(to: .now)
            check((1101...1105).allSatisfy { storage.installed(String($0)) }, "benchmark commits all five projects")
            print("BENCHMARK: 5 items; refresh delay 400 ms; elapsed \(duration); refresh callbacks \(refreshes). Fixture only, not Steam network throughput.")
            await model.shutdown()
            return
        }
        let storage = WorkshopStorage(root: root.appendingPathComponent("Coalescing"))
        var refreshGate: CheckedContinuation<Void, Never>?
        var refreshes = 0, concurrent = 0, maximumConcurrent = 0
        var published: Set<String> = []
        let model = WorkshopModel(storage: storage, defaults: defaults, component: executable,
            subscriptionCache: { nil }, onImported: { library in
                refreshes += 1; concurrent += 1; maximumConcurrent = max(maximumConcurrent, concurrent)
                let snapshot = publishedIDs(library)
                if refreshes == 1 { await withCheckedContinuation { refreshGate = $0 } }
                published = snapshot
                concurrent -= 1
            })
        model.account = "cached_user"
        for id in ["1001", "1002", "1003"] { model.downloadFromCard(item(id)) }
        try await wait { refreshGate != nil }
        try await wait { storage.installed("1003") && !model.taskBusy }
        check(model.downloadQueue.isEmpty, "next downloads finish while the first library refresh is held")
        check(model.downloadedIDs == ["1001", "1002", "1003"], "committed projects show downloaded immediately")
        check(model.busy, "pending library publication remains visible after the transfer queue drains")
        check(refreshes == 1 && maximumConcurrent == 1, "held library refresh never runs concurrent callbacks")
        let stage = try fm.contentsOfDirectory(at: storage.root.appendingPathComponent("Staging"), includingPropertiesForKeys: nil).first!
        let launches = try String(contentsOf: stage.appendingPathComponent("launches"), encoding: .utf8).split(separator: "\n")
        check(launches.count == 1, "all queued transfers reuse one authenticated Steam process")
        refreshGate?.resume(); refreshGate = nil
        try await wait { !model.busy }
        check(refreshes == 2 && maximumConcurrent == 1, "imports during a refresh produce one serial follow-up refresh")
        check(published == ["1001", "1002", "1003"], "follow-up refresh publishes every commit after the earlier snapshot")
        await model.shutdown()
        let quittingStorage = WorkshopStorage(root: root.appendingPathComponent("Shutdown"))
        var quittingGate: CheckedContinuation<Void, Never>?
        var registered = false, publicationCancelled = false, quitCompleted = false
        let quittingModel = WorkshopModel(storage: quittingStorage, defaults: defaults, component: executable,
            subscriptionCache: { nil }, onImported: { library in
                await withCheckedContinuation { quittingGate = $0 }
                publicationCancelled = Task.isCancelled
                registered = publishedIDs(library).contains("1004")
            })
        quittingModel.account = "cached_user"
        quittingModel.downloadFromCard(item("1004"))
        try await wait { quittingGate != nil }
        check(quittingStorage.installed("1004"), "shutdown fixture has already atomically committed its project")
        let shutdown = Task { await quittingModel.shutdown(); quitCompleted = true }
        try await Task.sleep(for: .milliseconds(100))
        check(!quitCompleted, "shutdown waits for publication of committed downloads")
        quittingGate?.resume(); quittingGate = nil
        await shutdown.value
        check(registered && !publicationCancelled, "shutdown does not cancel registration after an atomic commit")
        check(!quittingModel.busy && quittingModel.pendingDownload == nil, "shutdown drains owned publication and clears the queue")
        print("\(count) Workshop efficiency checks passed")
    }
}
