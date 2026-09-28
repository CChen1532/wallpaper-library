import Foundation

@main struct WorkshopManagementChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ name: String) { precondition(value, name); count += 1; print("PASS: " + name) }
        func rejects(_ name: String, _ action: () throws -> Void) {
            do { try action(); fatalError(name) } catch { check(true, name) }
        }
        func browseHTML(query: String = "mountain", page: Int = 1, total: Int = 1, pages: Int = 1, results: [[String: Any]]? = nil) throws -> String {
            let items = results ?? [["publishedfileid": "123", "consumer_appid": 431960, "title": "Snow \"Mountain\" 🏔", "short_description": "A \\\" quoted ) text", "file_size": "1024"]]
            let data: [String: Any] = ["eresult": 1, "current_page": page, "total_count": total, "total_pages": pages, "results": items]
            let key: [String: Any] = ["appid": 431960, "page": page, "search_text": query, "browse_sort": query.isEmpty ? "trend" : "textsearch", "search_text_target": 0]
            let queries: [String: Any] = ["queries": [["queryKey": ["workshop_browse", key], "state": ["data": data]]]]
            let q = String(decoding: try JSONSerialization.data(withJSONObject: queries), as: UTF8.self)
            let context = String(decoding: try JSONSerialization.data(withJSONObject: ["queryData": q]), as: UTF8.self)
            let literal = String(decoding: try JSONSerialization.data(withJSONObject: context, options: .fragmentsAllowed), as: UTF8.self)
            return "<script>window.SSR.renderContext=JSON.parse(\(literal))</script>"
        }
        let parsed = try WorkshopBrowse.decode(browseHTML(), query: "mountain", page: 1)
        check(parsed.items.first?.title == "Snow \"Mountain\" 🏔", "SSR decoding preserves quoted text and Unicode")
        check(parsed.total == 1 && parsed.items[0].bytes == 1024, "server totals and metadata decoded")
        check(parsed.items[0].summary.contains("quoted"), "description returned with search result")
        rejects("reject stale query response") { _ = try WorkshopBrowse.decode(browseHTML(), query: "sea", page: 1) }
        rejects("reject wrong page response") { _ = try WorkshopBrowse.decode(browseHTML(), query: "mountain", page: 2) }
        for html in ["<html>please login</html>", "window.SSR.renderContext=JSON.parse(", "window.SSR.renderContext=JSON.parse(\"broken"] {
            rejects("challenge or malformed HTML is not an empty search") { _ = try WorkshopBrowse.decode(html, query: "", page: 1) }
        }
        check(try WorkshopBrowse.decode(browseHTML(total: 0, pages: 0, results: []), query: "mountain", page: 1).items.isEmpty, "verified zero results accepted")
        let blocked: [[String: Any]] = [["publishedfileid": "1", "consumer_appid": 730], ["publishedfileid": "2", "consumer_appid": 431960, "banned": true], ["publishedfileid": "3", "consumer_appid": 431960, "visibility": 2], ["publishedfileid": "4", "consumer_appid": 431960, "file_type": 2]]
        check(try WorkshopBrowse.decode(browseHTML(results: blocked), query: "mountain", page: 1).items.isEmpty, "filter wrong application, banned, private and collection results")
        let queryURL = WorkshopBrowse.url(query: "雪 & p=99 # test", page: 2)
        let queryItems = URLComponents(url: queryURL, resolvingAgainstBaseURL: false)!.queryItems!
        check(queryItems.first { $0.name == "searchtext" }?.value == "雪 & p=99 # test" && queryItems.filter { $0.name == "p" }.count == 1, "search text cannot inject query parameters")

        let subscriptionURL = URL(string: "https://steamcommunity.com/profiles/76561198000000000/myworkshopfiles/?appid=431960&browsefilter=mysubscriptions&p=1")!
        let html = "<a href='https://steamcommunity.com/sharedfiles/filedetails/?id=123'>a</a><a href='https://steamcommunity.com/sharedfiles/filedetails/?id=123'>b</a><div class='workshopBrowsePagingInfo'>Showing 1-1 of 2 entries</div><a href='?appid=431960&amp;browsefilter=mysubscriptions&amp;p=2'>next</a>"
        let subscriptions = try WorkshopSubscriptionPage.decode(html, url: subscriptionURL, page: 1)
        check(subscriptions.ids == ["123"] && subscriptions.hasNext && subscriptions.total == 2, "subscription anchors deduplicated with escaped pagination")
        check(try WorkshopSubscriptionPage.decode("<div id='no_items'></div>", url: subscriptionURL, page: 1).total == 0, "explicit empty subscription page accepted")
        rejects("login URL is not an empty subscription list") { _ = try WorkshopSubscriptionPage.decode(html, url: URL(string: "https://steamcommunity.com/login")!, page: 1) }
        rejects("missing pagination evidence rejected") { _ = try WorkshopSubscriptionPage.decode("<a href='https://steamcommunity.com/sharedfiles/filedetails/?id=123'>x</a>", url: subscriptionURL, page: 1) }
        rejects("stale subscription page rejected") { _ = try WorkshopSubscriptionPage.decode(html, url: subscriptionURL, page: 2) }
        rejects("off-host subscription page rejected") { _ = try WorkshopSubscriptionPage.decode(html, url: URL(string: subscriptionURL.absoluteString.replacingOccurrences(of: "steamcommunity.com", with: "example.com"))!, page: 1) }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("WorkshopManagement-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let suite = "WorkshopManagement-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = root.appendingPathComponent("Materials")
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        MaterialDiscovery.setIncluded(true, folder: library, defaults: defaults)
        check(MaterialDiscovery.roots(home: root, defaults: defaults).map(\.path).contains(library.path), "source added to discovery")
        MaterialDiscovery.setIncluded(false, folder: library, defaults: defaults)
        check(!MaterialDiscovery.roots(home: root, defaults: defaults).map(\.path).contains(library.path) && fm.fileExists(atPath: library.path), "source removal persists without deleting directory")
        let defaultRoot = root.appendingPathComponent("Movies/Wallpapers2")
        MaterialDiscovery.setIncluded(false, folder: defaultRoot, defaults: defaults)
        check(!MaterialDiscovery.roots(home: root, defaults: defaults).map(\.path).contains(defaultRoot.path), "default source stays removed on next scan")
        MaterialDiscovery.setIncluded(true, folder: defaultRoot, defaults: defaults)
        check(MaterialDiscovery.roots(home: root, defaults: defaults).map(\.path).contains(defaultRoot.path), "adding a removed source enables it again")
        let scene = library.appendingPathComponent("Scene")
        try fm.createDirectory(at: scene, withIntermediateDirectories: true)
        let pkg = scene.appendingPathComponent("scene.pkg")
        try Data("fixture".utf8).write(to: pkg)
        let loose = library.appendingPathComponent("sibling.mp4")
        try Data("fixture".utf8).write(to: loose)
        check(try MaterialRemoval.target(for: pkg, roots: [library]).path == scene.path, "scene removal targets only its project")
        check(try MaterialRemoval.target(for: loose, roots: [library]) == loose, "loose video removal does not target its shared folder")
        rejects("reject payload outside registered root") { _ = try MaterialRemoval.target(for: loose, roots: [scene]) }
        let link = library.appendingPathComponent("link.mp4")
        try fm.createSymbolicLink(at: link, withDestinationURL: loose)
        rejects("reject symlink deletion target") { _ = try MaterialRemoval.target(for: link, roots: [library]) }
        let nestedRoot = scene.appendingPathComponent("OtherSource")
        rejects("project cannot delete another registered source") { _ = try MaterialRemoval.target(for: pkg, roots: [library, nestedRoot]) }
        if CommandLine.arguments.contains("--trash") {
            var trashed: NSURL?
            try fm.trashItem(at: loose, resultingItemURL: &trashed)
            guard let destination = trashed as URL? else { fatalError("Trash did not return a recoverable URL") }
            defer { if fm.fileExists(atPath: destination.path) { try? fm.moveItem(at: destination, to: loose) } }
            check(!fm.fileExists(atPath: loose.path) && fm.fileExists(atPath: destination.path), "real macOS Trash moves only the disposable fixture")
            try fm.moveItem(at: destination, to: loose)
            check(fm.fileExists(atPath: loose.path) && fm.fileExists(atPath: pkg.path), "Trash fixture restored and sibling scene preserved")
        }

        let storage = WorkshopStorage(root: root.appendingPathComponent("App"))
        let executable = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Tests/Fixtures/workshop-steam-fixture.py")
        var failMetadata = false, busyLibrary = false, imports = 0
        let model = WorkshopModel(storage: storage, defaults: defaults, libraryBusy: { busyLibrary }, component: executable, metadata: { ids in
            if failMetadata { throw WorkshopFailure.network }
            return ids.map { .init(id: $0, title: "Fixture " + $0, previewURL: nil, bytes: 1, tags: $0 == "110" ? ["Web"] : ["Video"]) }
        }, onImported: { _ in imports += 1 })
        model.account = "test_user"
        func idle() async throws {
            let deadline = Date().addingTimeInterval(12)
            while model.busy, Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
            check(!model.busy, "job finishes within bounded fixture time")
        }
        model.receiveSubscriptions(["101", "103", "107", "110"])
        try await idle()
        check(model.subscriptionCount == 4, "fresh subscription list published")
        let restored = WorkshopModel(storage: storage, defaults: defaults, component: executable,
                                     metadata: { _ in throw WorkshopFailure.network })
        let restoreDeadline = Date().addingTimeInterval(3)
        while !restored.subscriptionCacheLoaded && Date() < restoreDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        check(restored.subscriptionCacheLoaded && restored.subscriptionCount == 4 &&
              restored.subscriptions.map(\.id) == ["101", "103", "107", "110"],
              "saved subscriptions return after a model restart without network access")
        check(defaults.string(forKey: "workshopAccount") == "test_user",
              "Steam account name survives a model restart")
        failMetadata = true; model.receiveSubscriptions(["999"]); try await idle()
        check(model.subscriptions.map(\.id) == ["101", "103", "107", "110"], "failed list refresh preserves earlier subscriptions")
        model.recordRemoval(storage.destination("103"))
        check(model.ignoredCount == 1, "user deletion excluded from sync")
        busyLibrary = true; model.syncSubscriptions(password: "fixture; $(never-run) \"password\"")
        check(!model.busy, "sync cannot race a library mutation")
        busyLibrary = false; model.syncSubscriptions(password: "fixture; $(never-run) \"password\""); try await idle()
        check(storage.installed("101") && !storage.installed("103"), "missing project imported and deleted project stays absent")
        check(!storage.installed("107") && model.syncResults["107"] == "同步失败，可重试", "per-item failure remains retryable")
        check(model.syncResults["110"] == "格式暂不支持", "unsupported subscription skipped without launching download")
        check(imports == 1, "only validated imports published to library")

        model.syncSubscriptions(password: "fixture; $(never-run) \"password\""); try await idle()
        check(imports == 1 && model.syncResults["101"] == "已在资料库", "resync does not overwrite or duplicate existing item")
        let downloaded = storage.destination("101").appendingPathComponent("movie.mp4")
        check(try MaterialRemoval.target(for: downloaded, roots: [storage.library]).path == storage.destination("101").path, "declared video deletion includes its project so it can be downloaded again")
        model.restoreSyncItems()
        check(model.ignoredCount == 0, "explicit restore permits deleted items again")
        failMetadata = false; model.receiveSubscriptions(["104"]); try await idle()
        model.syncSubscriptions(password: "fixture; $(never-run) \"password\"")
        try await Task.sleep(for: .milliseconds(250)); model.cancel(); try await idle()
        check(!storage.installed("104") && model.syncResults["104"] == "待同步", "cancelled sync leaves no incomplete item")
        check(storage.installed("101"), "unsubscribing never removes an earlier local copy")
        check(!defaults.dictionaryRepresentation().values.contains { String(describing: $0).contains("never-run") }, "password never persisted in settings")

        await model.shutdown()
        check(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("App/Staging").path).isEmpty, "session staging removed on shutdown after success and failure")

        model.account = "cached_user"
        model.preconnect(); model.preconnect()
        check(model.connecting && !model.busy, "preconnect does not lock browsing activity")
        model.receiveSubscriptions(["401"])
        try await idle()
        let warmDeadline = Date().addingTimeInterval(4)
        while model.connecting && Date() < warmDeadline { try await Task.sleep(for: .milliseconds(20)) }
        check(model.connectionReady && !model.connecting && model.connectionError == nil, "cached account preconnect becomes ready")
        model.select(.init(id: "401", title: "Preconnected", previewURL: nil, bytes: 1, tags: ["Video"]))
        try await idle()
        model.download(password: "")
        try await idle()
        check(storage.installed("401"), "first download consumes preconnected session without a password")
        await model.shutdown()
        check(!model.connectionReady && !model.connecting, "shutdown clears connection state")
        model.account = "slow_user"
        model.preconnect()
        try await Task.sleep(for: .milliseconds(200))
        model.cancelConnection()
        await model.shutdown()
        check(!model.connecting && !model.connectionReady && model.connectionError == nil, "cancel preconnect cleans task without presenting an error")
        model.account = "test_user"
        model.preconnect()
        let authDeadline = Date().addingTimeInterval(4)
        while model.connecting && Date() < authDeadline { try await Task.sleep(for: .milliseconds(20)) }
        check(!model.connectionReady && model.connectionError == WorkshopFailure.passwordRequired.localizedDescription, "automatic auth failure asks user to sign in")
        await model.shutdown()
        check(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("App/Staging").path).isEmpty, "preconnect shutdown removes temporary staging")

        let existingCard = WorkshopItem(id: "401", title: "Existing", previewURL: nil, bytes: 1, tags: ["Video"])
        let directCard = WorkshopItem(id: "501", title: "Direct", previewURL: nil, bytes: 1, tags: ["Video"])
        var lookups = 0, cardImports = 0
        let cards = WorkshopModel(storage: storage, defaults: defaults, findExisting: { _ in lookups += 1; return nil },
                                  component: executable, browse: { _, page in
            .init(items: [existingCard, directCard], number: page, pages: 2, total: 2)
        }, onImported: { _ in cardImports += 1 })
        func cardsIdle() async throws {
            let deadline = Date().addingTimeInterval(5)
            while (cards.busy || cards.connecting), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            check(!cards.busy && !cards.connecting, "card task completes within fixture deadline")
        }
        cards.search(); try await cardsIdle()
        let cacheDeadline = Date().addingTimeInterval(3)
        while !cards.downloadedIDs.contains("401") && Date() < cacheDeadline { try await Task.sleep(for: .milliseconds(20)) }
        check(cards.cardState(existingCard) == .downloaded && cards.cardState(directCard) == .available, "page status distinguishes installed and missing projects")
        let lookupsBefore = lookups
        let statusStart = Date()
        for _ in 0..<20_000 { _ = cards.cardState(existingCard); _ = cards.cardState(directCard) }
        check(lookups == lookupsBefore, "40,000 card status reads perform zero library or disk lookups")
        print("CARD STATUS 40,000 reads: \(Date().timeIntervalSince(statusStart) * 1000) ms; not frame-rate evidence")
        cards.account = "cached_user"
        cards.preconnect()
        cards.downloadFromCard(directCard)
        cards.downloadFromCard(existingCard)
        check(cards.pendingDownload?.id == "501", "click during preconnect retains exactly one requested item")
        try await cardsIdle()
        check(storage.installed("501") && cards.cardState(directCard) == .downloaded && cardImports == 1,
              "one card click automatically downloads after preconnect and marks complete")
        cards.downloadFromCard(directCard)
        check(!cards.busy && cardImports == 1, "downloaded card cannot start another transfer")
        let already = WorkshopItem(id: "101", title: "Uncached existing", previewURL: nil, bytes: 1, tags: ["Video"])
        cards.downloadFromCard(already); try await cardsIdle()
        check(cards.cardState(already) == .downloaded && cardImports == 1, "click-time recheck prevents redownloading an uncached local project")
        let failed = WorkshopItem(id: "107", title: "Failed", previewURL: nil, bytes: 1, tags: ["Video"])
        cards.downloadFromCard(failed); try await cardsIdle()
        check(cards.cardState(failed) == .failed && cards.error != nil, "failed download is retryable and never marked downloaded")
        await cards.shutdown()
        cards.account = "test_user"
        let authCard = WorkshopItem(id: "502", title: "Auth retry", previewURL: nil, bytes: 1, tags: ["Video"])
        cards.downloadFromCard(authCard); try await cardsIdle()
        check(cards.authenticationRequired && cards.pendingDownload?.id == "502", "expired login keeps clicked item for authentication")
        cards.preconnect(password: "fixture; $(never-run) \"password\"", automatic: false)
        try await cardsIdle()
        check(storage.installed("502") && !cards.authenticationRequired && cards.pendingDownload == nil,
              "sign-in resumes original download without a second download click")
        cards.account = "cached_user"; cards.preconnect(); try await cardsIdle()
        func queued(_ id: String) -> WorkshopItem { .init(id: id, title: "Queue " + id, previewURL: nil, bytes: 1, tags: ["Video"]) }
        let beforeQueue = cardImports
        cards.downloadFromCard(queued("601")); cards.downloadFromCard(queued("602")); cards.downloadFromCard(queued("603"))
        cards.downloadFromCard(queued("601")); cards.downloadFromCard(queued("603"))
        check(cards.activeDownloadID == "601" && cards.downloadQueue.map(\.id) == ["602", "603"], "rapid clicks queue multiple items in order without duplicate active or queued IDs")
        check(cards.cardState(queued("603")) == .queued, "waiting card displays queued status")
        cards.removeQueuedDownload("602")
        try await cardsIdle()
        check(storage.installed("601") && storage.installed("603") && !storage.installed("602") && cardImports == beforeQueue + 2,
              "queue automatically drains and individually removed item never downloads")
        cards.downloadFromCard(queued("104")); cards.downloadFromCard(queued("604"))
        try await Task.sleep(for: .milliseconds(180)); cards.cancel(); try await cardsIdle()
        check(!storage.installed("104") && storage.installed("604"), "cancel current transfer continues with the next queued item")
        cards.downloadFromCard(queued("107")); cards.downloadFromCard(queued("605")); try await cardsIdle()
        check(cards.cardState(queued("107")) == .failed && storage.installed("605"), "failed item stays retryable while remaining queue continues")

        try fm.removeItem(at: storage.destination("401"))
        cards.recordRemoval(storage.destination("401")); cards.refreshDownloadedStatus()
        check(cards.cardState(existingCard) == .available, "removing local project immediately clears downloaded badge")
        await cards.shutdown()
        cards.account = "slow_user"; cards.preconnect()
        let waitingCard = WorkshopItem(id: "503", title: "Cancelled wait", previewURL: nil, bytes: 1, tags: ["Video"])
        cards.downloadFromCard(waitingCard); cards.cancelPendingDownload()
        await cards.shutdown()
        check(cards.pendingDownload == nil && !storage.installed("503"), "cancelled pending card is never downloaded")

        if CommandLine.arguments.contains("--live") {
            let first = try await WorkshopBrowse.fetch(query: "mountain", page: 1)
            let second = try await WorkshopBrowse.fetch(query: "mountain", page: 2)
            check(!first.items.isEmpty && second.number == 2 && first.pages > 1, "real public full-text search and second page")
            check(Set(first.items.map(\.id)) != Set(second.items.map(\.id)), "real pagination yields another set")
            let empty = try await WorkshopBrowse.fetch(query: "qzzwallpaperuinoresult94726183", page: 1)
            check(empty.total == 0 && empty.items.isEmpty, "real zero-result search")
        }
        print("\(count) Workshop management checks passed")
    }
}
