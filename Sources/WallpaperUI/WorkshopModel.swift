import Foundation
import Combine

@MainActor final class WorkshopModel: ObservableObject {
    enum Activity { case idle, lookup, component, download, importing, search, subscriptions }
    @Published var link = ""
    @Published var account: String {
        didSet { defaults.set(account, forKey: "workshopAccount") }
    }
    @Published private(set) var item: WorkshopItem?
    @Published private(set) var activity = Activity.idle
    @Published private(set) var event = WorkshopSteamEvent.preparing
    @Published private(set) var error: String?
    @Published private(set) var component: URL?
    @Published private(set) var importedURL: URL?
    @Published private(set) var cancelling = false
    @Published var searchText = ""
    @Published private(set) var searchPage: WorkshopBrowse.Page?
    @Published private(set) var searchedText = ""
    @Published private(set) var filters: WorkshopFilters
    private var searchedRequest: WorkshopBrowse.Request?
    @Published private(set) var subscriptions: [WorkshopItem] = []
    @Published private(set) var subscriptionCount = 0
    @Published private(set) var subscriptionReadAt: Date?
    @Published private(set) var subscriptionCacheLoaded = false
    @Published private(set) var syncResults: [String: String] = [:]
    @Published private(set) var syncing = false
    @Published private(set) var syncPosition = 0
    @Published private(set) var syncTotal = 0
    @Published private(set) var downloadTitle = ""
    let storage: WorkshopStorage
    private var job: Task<Void, Never>?
    private var process: WorkshopSteamProcess?
    private let defaults: UserDefaults
    private let onImported: (URL) async -> Void
    private let findExisting: (String) -> URL?
    private let libraryBusy: () -> Bool
    private let metadata: ([String]) async throws -> [WorkshopItem]
    private let browse: (WorkshopBrowse.Request, Int) async throws -> WorkshopBrowse.Page
    var busy: Bool { activity != .idle }
    var waitingForGuard: Bool { event == .guardCode && activity == .download && !cancelling }

    init(storage: WorkshopStorage = WorkshopStorage(), defaults: UserDefaults = .standard,
         findExisting: @escaping (String) -> URL? = { _ in nil }, libraryBusy: @escaping () -> Bool = { false },
         component: URL? = nil, metadata: @escaping ([String]) async throws -> [WorkshopItem] = { try await WorkshopMetadata.fetch(ids: $0) },
         browse: @escaping (WorkshopBrowse.Request, Int) async throws -> WorkshopBrowse.Page = { try await WorkshopBrowse.fetch(request: $0, page: $1) },
         onImported: @escaping (URL) async -> Void = { _ in }) {
        self.storage = storage; self.defaults = defaults; self.onImported = onImported
        self.findExisting = findExisting
        self.libraryBusy = libraryBusy
        self.metadata = metadata
        self.browse = browse
        filters = defaults.data(forKey: "workshopBrowseFilters").flatMap { try? JSONDecoder().decode(WorkshopFilters.self, from: $0) } ?? .init()
        account = defaults.string(forKey: "workshopAccount") ?? ""
        self.component = component ?? WorkshopComponent.locate(storage: storage, custom: defaults.string(forKey: "workshopSteamCMD"))
        Task { [weak self] in
            let cached = await Task.detached(priority: .utility) { storage.loadSubscriptions() }.value
            guard let self, let cached, self.subscriptionReadAt == nil, !self.busy else { return }
            self.subscriptions = cached.items
            self.subscriptionCount = cached.total
            self.subscriptionReadAt = cached.readAt
            self.subscriptionCacheLoaded = true
        }
    }

    func setFilters(_ value: WorkshopFilters, searchImmediately: Bool = true) {
        guard !busy, filters != value else { return }
        filters = value
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "workshopBrowseFilters") }
        searchPage = nil; searchedRequest = nil; item = nil; importedURL = nil; error = nil
        if searchImmediately, value.period != .custom { search() }
    }
    func search(page requestedPage: Int? = nil) {
        guard !busy, filters.validDates else { return }
        let request: WorkshopBrowse.Request
        let page: Int
        if let requestedPage {
            guard let previous = searchedRequest, let previousPage = searchPage,
                  requestedPage >= 1, requestedPage <= max(1, previousPage.pages) else { return }
            request = previous; page = requestedPage
        } else {
            request = .init(query: String(searchText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)), filters: filters)
            page = 1; searchPage = nil; searchedRequest = nil; item = nil; importedURL = nil
        }
        activity = .search; error = nil
        job = Task {
            defer { finish() }
            do {
                let result = try await browse(request, page)
                try Task.checkCancellation()
                searchPage = result; searchedText = request.query; searchedRequest = request; item = nil; importedURL = nil
            } catch { record(error) }
        }
    }
    func select(_ value: WorkshopItem) {
        guard !busy else { return }
        item = value; link = value.id; error = nil
        importedURL = nil; activity = .lookup
        job = Task {
            defer { finish() }
            let url = await existing(value.id)
            if !Task.isCancelled { importedURL = url }
        }
    }
    private func existing(_ id: String) async -> URL? {
        if let found = findExisting(id) { return found }
        let storage = self.storage
        let installed = await Task.detached(priority: .utility) { storage.installed(id) }.value
        return installed ? storage.destination(id) : nil
    }
    private var ignoredIDs: Set<String> { Set(defaults.stringArray(forKey: "workshopSyncIgnoredIDs") ?? []) }
    func recordRemoval(_ target: URL) {
        let id = target.lastPathComponent
        guard case .ok = WorkshopURLParser.parse(id) else { return }
        var ignored = ignoredIDs; ignored.insert(id)
        defaults.set(ignored.sorted(), forKey: "workshopSyncIgnoredIDs")
        syncResults[id] = "已跳过"
        if item?.id == id { importedURL = nil }
    }
    func restoreSyncItems() {
        guard !busy else { return }
        defaults.removeObject(forKey: "workshopSyncIgnoredIDs")
        syncResults = [:]
    }
    var ignoredCount: Int { subscriptions.filter { ignoredIDs.contains($0.id) }.count }
    func subscriptionStatus(_ value: WorkshopItem) -> String {
        if let status = syncResults[value.id] { return status }
        if ignoredIDs.contains(value.id) { return "已跳过" }
        return "待同步"
    }
    func receiveSubscriptions(_ ids: [String]) {
        guard !busy else { return }
        activity = .subscriptions; error = nil
        job = Task {
            defer { finish() }
            do {
                let items = try await metadata(ids)
                try Task.checkCancellation()
                var statuses: [String: String] = [:]
                for item in items { if await existing(item.id) != nil { statuses[item.id] = "已在资料库" } }
                try Task.checkCancellation()
                let snapshot = WorkshopSubscriptionSnapshot(total: ids.count, readAt: Date(), items: items)
                let storage = self.storage
                try await Task.detached(priority: .utility) { try storage.saveSubscriptions(snapshot) }.value
                try Task.checkCancellation()
                subscriptions = items; subscriptionCount = ids.count; subscriptionReadAt = Date(); syncResults = statuses
                subscriptionCacheLoaded = false
            } catch { record(error) }
        }
    }
    func syncSubscriptions(password: String) {
        guard !busy, !libraryBusy(), subscriptionReadAt != nil else { return }
        guard let component else { error = WorkshopFailure.componentMissing.localizedDescription; return }
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WorkshopSteamProcess.validCredentials(account: account, password: password) else { error = WorkshopFailure.invalidAccount.localizedDescription; return }
        defaults.set(account, forKey: "workshopAccount")
        let queue = subscriptions.filter { !ignoredIDs.contains($0.id) }
        syncing = true; syncPosition = 0; syncTotal = queue.count; error = nil; activity = .download
        syncResults = [:]
        job = Task {
            defer { process = nil; syncing = false; downloadTitle = ""; finish() }
            for (index, value) in queue.enumerated() {
                if Task.isCancelled { break }
                syncPosition = index + 1; downloadTitle = value.title
                if await existing(value.id) != nil { syncResults[value.id] = "已在资料库"; continue }
                if Task.isCancelled { break }
                let tags = value.tags.map { $0.lowercased() }
                if tags.contains("web") || tags.contains("application") { syncResults[value.id] = "格式暂不支持"; continue }
                syncResults[value.id] = "正在同步"
                do {
                    _ = try await downloadOne(value, component: component, account: account, password: password)
                    syncResults[value.id] = "已加入资料库"
                } catch {
                    if error is CancellationError || Task.isCancelled { syncResults[value.id] = "待同步"; break }
                    syncResults[value.id] = "同步失败，可重试"
                    record(error)
                    if let failure = error as? WorkshopFailure, failure == .loginFailed || failure == .launchFailed { break }
                }
            }
        }
    }
    func refreshComponent() {
        guard !busy else { return }
        component = WorkshopComponent.locate(storage: storage, custom: defaults.string(forKey: "workshopSteamCMD"))
    }
    func selectComponent(_ url: URL) {
        guard !busy else { return }
        let binary = url.resolvingSymlinksInPath()
        guard WorkshopComponent.validBinary(binary) else { error = WorkshopFailure.componentInvalid.localizedDescription; return }
        defaults.set(binary.path, forKey: "workshopSteamCMD"); component = binary; error = nil
    }

    func lookup() {
        guard !busy else { return }
        error = nil; item = nil; importedURL = nil
        guard case let .ok(number, _) = WorkshopURLParser.parse(link) else { error = WorkshopFailure.invalidLink.localizedDescription; return }
        let id = String(number)
        activity = .lookup
        job = Task {
            defer { finish() }
            do {
                let result = try await WorkshopMetadata.fetch(id: id)
                try Task.checkCancellation()
                let storage = self.storage
                let installed = await Task.detached(priority: .utility) { storage.installed(id) }.value
                try Task.checkCancellation()
                item = result
                if installed { importedURL = storage.destination(id) }
                else { importedURL = findExisting(id) }
            } catch { record(error) }
        }
    }

    func installComponent() {
        guard !busy else { return }
        activity = .component; error = nil
        job = Task {
            defer { finish() }
            do { component = try await WorkshopComponent.install(storage: storage) }
            catch { record(error) }
        }
    }
    func registerImported() async {
        guard !busy, let importedURL, MaterialRemoval.contains(storage.library, importedURL) else { return }
        await onImported(storage.library)
    }

    func download(password: String) {
        guard !busy, !libraryBusy(), let item, importedURL == nil else { return }
        guard WorkshopFilters.supportsPlayback(tags: item.tags) else { error = WorkshopFailure.unsupportedProject.localizedDescription; return }
        if let existing = findExisting(item.id) { importedURL = existing; return }
        guard let component else { error = WorkshopFailure.componentMissing.localizedDescription; return }
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WorkshopSteamProcess.validCredentials(account: account, password: password) else { error = WorkshopFailure.invalidAccount.localizedDescription; return }
        defaults.set(account, forKey: "workshopAccount")
        activity = .download; event = .preparing; error = nil
        job = Task {
            defer { process = nil; finish() }
            do {
                importedURL = try await downloadOne(item, component: component, account: account, password: password)
                var ignored = ignoredIDs; ignored.remove(item.id)
                defaults.set(ignored.sorted(), forKey: "workshopSyncIgnoredIDs")
            } catch { record(error) }
        }
    }

    private func downloadOne(_ item: WorkshopItem, component: URL, account: String, password: String) async throws -> URL {
        let worker = WorkshopSteamProcess(); process = worker; activity = .download; event = .preparing
        let stage = try storage.makeStaging()
        defer { try? FileManager.default.removeItem(at: stage) }
        let source = try await worker.download(binary: component, account: account, password: password, id: item.id, staging: stage) { [weak self] event in
            Task { @MainActor in
                guard let self, self.process === worker, self.activity == .download else { return }
                self.event = event
            }
        }
        try Task.checkCancellation()
        activity = .importing
        let storage = self.storage
        let importer = Task.detached(priority: .utility) { try storage.importProject(from: source, item: item, consumeStagedFiles: true) }
        let imported = try await withTaskCancellationHandler(operation: { try await importer.value }, onCancel: { importer.cancel() })
        // Publish complete imports even when cancellation arrives just after the atomic rename.
        await onImported(storage.library)
        return imported
    }

    func submitGuard(_ code: String) -> Bool {
        guard waitingForGuard else { return false }
        if process?.submitGuardCode(code) == true { event = .signingIn; return true }
        return false
    }
    func cancel() {
        guard busy else { return }
        cancelling = true; process?.cancel(); job?.cancel()
    }
    func shutdown() async { cancel(); await job?.value }
    private func finish() { activity = .idle; cancelling = false; job = nil }
    private func record(_ failure: Error) {
        guard !(failure is CancellationError), !Task.isCancelled else { return }
        error = (failure as? WorkshopFailure)?.localizedDescription ?? "无法完成文件操作，请检查磁盘空间与文件夹权限。"
    }
}
