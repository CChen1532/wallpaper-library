import Foundation

@main struct WorkshopBrowsingChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); count += 1; print("PASS: " + message) }
        func wait(_ condition: @MainActor () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(6)
            while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            precondition(condition(), "fixture wait exceeded deadline")
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Workshop Browsing " + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let executable = root.appendingPathComponent("steamcmd")
        try fm.copyItem(at: URL(fileURLWithPath: "Tests/Fixtures/workshop-steam-fixture.py"), to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let suite = "WorkshopBrowsing-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = WorkshopStorage(root: root.appendingPathComponent("App"))
        func item(_ id: String) -> WorkshopItem { .init(id: id, title: "Fixture " + id, previewURL: nil, bytes: 1, tags: ["Video"]) }
        var heldBrowse: CheckedContinuation<Void, Never>?
        var holdBrowse = false, failBrowse = false, delayBrowse = false
        var imports = 0, libraryBusy = false
        let model = WorkshopModel(storage: storage, defaults: defaults, libraryBusy: { libraryBusy }, component: executable,
            metadata: { ids in ids == ["999"] ? [] : ids.map(item) }, browse: { _, page in
                if holdBrowse { await withCheckedContinuation { heldBrowse = $0 } }
                if delayBrowse { try? await Task.sleep(for: .milliseconds(200)) }
                if failBrowse { throw WorkshopFailure.network }
                return .init(items: [item("801"), item("802")], number: page, pages: 3, total: 6)
            }, onImported: { _ in imports += 1 })
        model.account = "cached_user"
        model.search(); try await wait { !model.busy }
        model.downloadFromCard(item("104"))
        try await wait { model.downloadProgress != nil }
        check(!model.browseLocked && model.taskBusy, "active transfer leaves public browsing unlocked")
        model.searchText = "unsubmitted edit"; model.search(page: 2)
        try await wait { !model.browseBusy }
        check(model.searchPage?.number == 2 && model.activeDownloadID == "104", "pagination succeeds without replacing active download")
        var filters = model.filters; filters.sort = .latest
        model.setFilters(filters); try await wait { !model.browseBusy }
        check(model.filters == filters && model.activeDownloadID == "104", "filter search and transfer run independently")
        model.link = "802"; model.lookup(); try await wait { !model.browseBusy }
        check(model.item?.id == "802" && model.activeDownloadID == "104", "link lookup remains usable during transfer")
        model.link = "999"; model.lookup(); try await wait { !model.browseBusy }
        check(model.browseError == WorkshopFailure.unavailable.localizedDescription && model.taskError == nil, "unavailable lookup has its own error and preserves transfer")
        model.select(item("801")); try await wait { !model.browseBusy }
        check(model.item?.id == "801" && model.activeDownloadID == "104", "other wallpaper details can be opened during transfer")
        model.download(password: "")
        check(model.downloadQueue.map(\.id) == ["801"], "download from another detail joins queue")
        failBrowse = true; model.search(); try await wait { !model.browseBusy }
        check(model.browseError != nil && model.taskError == nil && model.activeDownloadID == "104", "browse failure does not fail or overwrite transfer")
        failBrowse = false; delayBrowse = true; model.search(); model.cancelBrowsing()
        try await wait { !model.browseBusy }
        check(model.browseError == nil && model.activeDownloadID == "104", "browse cancellation leaves active transfer intact")
        // Stop this fixture, then use a held browse response to prove queue drain is independent.
        await model.shutdown()
        check(!model.busy && model.downloadQueue.isEmpty && !storage.installed("104") && !storage.installed("801"), "shutdown cancels both lanes and prevents queued work revival")
        delayBrowse = false
        model.select(item("803")); try await wait { !model.browseBusy }
        model.downloadFromCard(item("804")); model.downloadFromCard(item("805"))
        check(model.item?.id == "803" && model.link == "803", "starting queue preserves selected details and link")
        holdBrowse = true; model.searchText = "browse while downloading"; model.search()
        try await wait { heldBrowse != nil }
        try await wait { !model.taskBusy }
        check(model.browseBusy && imports == 2 && storage.installed("804") && storage.installed("805"), "queue imports every item while browser response remains pending")
        check(model.searchText == "browse while downloading" && model.item == nil, "queue advancement does not replace browser selection or search text")
        heldBrowse?.resume(); heldBrowse = nil; holdBrowse = false
        try await wait { !model.busy }
        check(model.searchPage?.number == 1, "pending browser result publishes after queue completion")
        model.select(item("803")); try await wait { !model.browseBusy }
        model.downloadFromCard(item("806")); try await wait { !model.busy }
        check(model.item?.id == "803" && model.importedURL == nil && storage.installed("806"), "another item's completion never marks selected wallpaper as imported")
        model.downloadFromCard(item("104")); try await wait { model.downloadProgress != nil }
        delayBrowse = true; model.search(); model.cancel()
        try await wait { !model.busy }
        check(model.searchPage != nil && !storage.installed("104"), "cancel transfer preserves independent browser result")
        delayBrowse = true; model.search(); model.downloadFromCard(item("104")); model.downloadFromCard(item("807"))
        await model.shutdown()
        check(!model.busy && model.pendingDownload == nil && !storage.installed("807"), "combined shutdown awaits browse and download and clears queue")
        delayBrowse = false
        model.downloadFromCard(item("808")); model.downloadFromCard(item("809"))
        libraryBusy = true
        try await wait { !model.taskBusy }
        check(storage.installed("808") && model.pendingDownload?.id == "809" && !storage.installed("809"),
              "playback busy at import completion temporarily holds the next queued item")
        libraryBusy = false
        try await wait { storage.installed("809") && !model.taskBusy }
        check(model.pendingDownload == nil, "clearing playback busy automatically resumes and drains the queue")

        model.downloadFromCard(item("810")); model.downloadFromCard(item("811"))
        libraryBusy = true
        try await wait { !model.taskBusy }
        check(model.pendingDownload?.id == "811", "clear-queue fixture reaches the blocked waiter")
        model.cancelPendingDownload(); libraryBusy = false
        try await Task.sleep(for: .milliseconds(500))
        check(model.pendingDownload == nil && !model.taskBusy && !storage.installed("811"),
              "clearing a blocked queue cancels its waiter without reviving downloads")

        model.downloadFromCard(item("812")); model.downloadFromCard(item("813"))
        libraryBusy = true
        try await wait { !model.taskBusy }
        check(model.pendingDownload?.id == "813", "shutdown fixture reaches the blocked waiter")
        await model.shutdown(); libraryBusy = false
        try await Task.sleep(for: .milliseconds(500))
        check(model.pendingDownload == nil && !model.taskBusy && !storage.installed("813"),
              "shutdown awaits and cancels a blocked queue without post-exit downloads")
        print("\(count) concurrent browsing checks passed")
    }
}
