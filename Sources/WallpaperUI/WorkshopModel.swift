import Foundation
import Combine

@MainActor final class WorkshopModel: ObservableObject {
    enum Activity { case idle, lookup, component, download, importing, search, subscriptions }
    @Published var link = ""
    @Published var account: String {
        didSet { defaults.set(account, forKey: "workshopAccount"); if oldValue != account { connectionReady = false; connectionError = nil } }
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
    @Published private(set) var connecting = false
    @Published private(set) var connectionReady = false
    @Published private(set) var connectionEvent = WorkshopSteamEvent.preparing
    @Published private(set) var connectionError: String?
    private var connectionJob: Task<Void, Never>?
    private var connectionToken: UUID?
    enum CardState: Equatable { case available, failed, downloaded, queued, waiting, downloading, importing, unsupported }
    @Published private(set) var downloadedIDs: Set<String> = []
    @Published private(set) var downloadQueue: [WorkshopItem] = [] {
        didSet { queuedIDs = Set(downloadQueue.map(\.id)) }
    }
    private var queuedIDs: Set<String> = []
    @Published private(set) var failedDownloads: [String: WorkshopItem] = [:]
    var pendingDownload: WorkshopItem? { downloadQueue.first }
    @Published private(set) var authenticationRequired = false
    @Published private(set) var activeDownloadID: String?
    private var installedJob: Task<Void, Never>?
    private var installedRevision = UUID()
    let storage: WorkshopStorage
    private var job: Task<Void, Never>?
    private var process: WorkshopSteamProcess?
    private let downloadWorker = WorkshopSteamProcess()
    private var downloadStage: URL?
    private var downloadToken: UUID?
    private let defaults: UserDefaults
    private let onImported: (URL) async -> Void
    private let findExisting: (String) -> URL?
    private let libraryBusy: () -> Bool
    private let metadata: ([String]) async throws -> [WorkshopItem]
    private let browse: (WorkshopBrowse.Request, Int) async throws -> WorkshopBrowse.Page
    var busy: Bool { activity != .idle }
    var waitingForGuard: Bool {
        (connecting && connectionEvent == .guardCode) || (event == .guardCode && activity == .download && !cancelling)
    }
    var steamBusy: Bool { connecting || activity == .download || activity == .importing || activity == .component }

    /// Connection work has its own task so search, filters and cards remain usable.
    func preconnect(password: String = "", automatic: Bool = true) {
        guard !steamBusy else { return }
        guard let component else { return }
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WorkshopSteamProcess.validCredentials(account: account, password: password) else {
            if !automatic { connectionError = WorkshopFailure.invalidAccount.localizedDescription }
            return
        }
        connecting = true; connectionReady = false; connectionError = nil; connectionEvent = .preparing
        let token = UUID(); connectionToken = token
        connectionJob = Task {
            defer {
                connecting = false; connectionJob = nil; connectionToken = nil
                if connectionReady { authenticationRequired = false; resumePendingDownload() }
                else if pendingDownload != nil, !Task.isCancelled { authenticationRequired = true }
            }
            do {
                let stage = try sessionStaging()
                try await downloadWorker.connect(binary: component, account: account, password: password, staging: stage) { [weak self] event in
                    Task { @MainActor in
                        guard let self, self.connecting, self.connectionToken == token else { return }
                        self.connectionEvent = event
                        if self.pendingDownload != nil && (event == .guardCode || event == .mobileApproval) {
                            self.authenticationRequired = true
                        }
                    }
                }
                try Task.checkCancellation()
                connectionReady = true
            } catch {
                await discardSession()
                if !(error is CancellationError), !Task.isCancelled {
                    connectionError = (error as? WorkshopFailure)?.localizedDescription ?? WorkshopFailure.launchFailed.localizedDescription
                }
            }
        }
    }
    func cancelConnection() {
        connectionJob?.cancel(); connectionReady = false
        downloadQueue = []; authenticationRequired = false
    }

    func cardState(_ value: WorkshopItem) -> CardState {
        if downloadedIDs.contains(value.id) { return .downloaded }
        if activeDownloadID == value.id { return activity == .importing ? .importing : .downloading }
        if queuedIDs.contains(value.id) {
            return pendingDownload?.id == value.id && (connecting || authenticationRequired) ? .waiting : .queued
        }
        if failedDownloads[value.id] != nil { return .failed }
        return WorkshopFilters.supportsPlayback(tags: value.tags) ? .available : .unsupported
    }

    var downloadProgress: WorkshopDownloadProgress? {
        guard activity == .download else { return nil }
        switch event {
        case .transfer(let value): return value
        case .downloading(let fraction): return .init(fraction: fraction)
        default: return nil
        }
    }
    func cardProgress(_ value: WorkshopItem) -> WorkshopDownloadProgress? {
        activeDownloadID == value.id ? downloadProgress : nil
    }

    /// Only page changes/explicit refreshes inspect disk, never a card's body or hover callback.
    func refreshDownloadedStatus() {
        installedJob?.cancel()
        let revision = UUID(); installedRevision = revision
        let ids = Set(searchPage?.items.map(\.id) ?? [])
        guard !ids.isEmpty else { return }
        let known = Set(ids.filter { findExisting($0) != nil })
        let storage = self.storage
        installedJob = Task {
            let scan = Task.detached(priority: .utility) { () -> Set<String> in
                var result = known
                for id in ids.subtracting(known) {
                    if Task.isCancelled { break }
                    if storage.installed(id) { result.insert(id) }
                }
                return result
            }
            let found = await withTaskCancellationHandler(operation: { await scan.value }, onCancel: { scan.cancel() })
            guard !Task.isCancelled, installedRevision == revision else { return }
            let updated = downloadedIDs.subtracting(ids).union(found)
            if updated != downloadedIDs { downloadedIDs = updated }
            installedJob = nil
        }
    }
    private func markDownloaded(_ id: String) {
        installedRevision = UUID(); installedJob?.cancel()
        if !downloadedIDs.contains(id) { downloadedIDs.insert(id) }
    }

    /// Card action is a download request, not a detail selection.
    func downloadFromCard(_ value: WorkshopItem) {
        guard !libraryBusy(), WorkshopFilters.supportsPlayback(tags: value.tags),
              !downloadedIDs.contains(value.id), !queuedIDs.contains(value.id), activeDownloadID != value.id else { return }
        failedDownloads.removeValue(forKey: value.id)
        downloadQueue.append(value)
        if connecting && (connectionEvent == .guardCode || connectionEvent == .mobileApproval) { authenticationRequired = true }
        resumePendingDownload()
    }
    private func resumePendingDownload() {
        guard !connecting, !busy, !libraryBusy(), !authenticationRequired, let value = pendingDownload else { return }
        guard component != nil,
              WorkshopSteamProcess.validCredentials(account: account.trimmingCharacters(in: .whitespacesAndNewlines), password: ""),
              connectionError == nil else { authenticationRequired = true; return }
        downloadQueue.removeFirst()
        item = value; link = value.id; importedURL = nil
        download(password: "", fromCard: true)
    }
    func removeQueuedDownload(_ id: String) {
        downloadQueue.removeAll { $0.id == id }
        if downloadQueue.isEmpty, activity != .download { authenticationRequired = false }
    }
    func cancelPendingDownload() {
        downloadQueue = []
        if activity != .download { authenticationRequired = false }
    }

    private func sessionStaging() throws -> URL {
        if let downloadStage { return downloadStage }
        let stage = try storage.makeStaging(); downloadStage = stage
        return stage
    }
    private func discardSession() async {
        await downloadWorker.closeSession()
        if let downloadStage { try? FileManager.default.removeItem(at: downloadStage) }
        downloadStage = nil; connectionReady = false
    }

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
                refreshDownloadedStatus()
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
        installedRevision = UUID(); installedJob?.cancel(); downloadedIDs.remove(id)
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
        guard !busy, !connecting, !libraryBusy(), subscriptionReadAt != nil else { return }
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
        guard !busy, !connecting else { return }
        let previous = component
        component = WorkshopComponent.locate(storage: storage, custom: defaults.string(forKey: "workshopSteamCMD"))
        if previous != component { connectionReady = false }
    }
    func selectComponent(_ url: URL) {
        guard !busy, !connecting else { return }
        let binary = url.resolvingSymlinksInPath()
        guard WorkshopComponent.validBinary(binary) else { error = WorkshopFailure.componentInvalid.localizedDescription; return }
        defaults.set(binary.path, forKey: "workshopSteamCMD"); component = binary; error = nil; connectionReady = false
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
        guard !busy, !connecting else { return }
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

    func download(password: String, fromCard: Bool = false) {
        guard !busy, !connecting, !libraryBusy(), let item, importedURL == nil else { return }
        guard WorkshopFilters.supportsPlayback(tags: item.tags) else { error = WorkshopFailure.unsupportedProject.localizedDescription; return }
        guard let component else { error = WorkshopFailure.componentMissing.localizedDescription; return }
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WorkshopSteamProcess.validCredentials(account: account, password: password) else { error = WorkshopFailure.invalidAccount.localizedDescription; return }
        defaults.set(account, forKey: "workshopAccount")
        activity = .download; event = .preparing; error = nil
        activeDownloadID = item.id; downloadTitle = item.title
        job = Task {
            defer { process = nil; activeDownloadID = nil; finish() }
            do {
                // Recheck local state at click time even if the page cache has not loaded yet.
                if let existing = await existing(item.id) {
                    importedURL = existing; markDownloaded(item.id); return
                }
                try Task.checkCancellation()
                importedURL = try await downloadOne(item, component: component, account: account, password: password)
                var ignored = ignoredIDs; ignored.remove(item.id)
                defaults.set(ignored.sorted(), forKey: "workshopSyncIgnoredIDs")
                authenticationRequired = false
            } catch {
                if fromCard, error as? WorkshopFailure == .passwordRequired || error as? WorkshopFailure == .loginFailed {
                    downloadQueue.insert(item, at: 0); authenticationRequired = true
                    connectionError = (error as? WorkshopFailure)?.localizedDescription
                } else {
                    if fromCard, !(error is CancellationError), !Task.isCancelled { failedDownloads[item.id] = item }
                    record(error)
                }
            }
        }
    }

    private func downloadOne(_ item: WorkshopItem, component: URL, account: String, password: String) async throws -> URL {
        activeDownloadID = item.id; downloadTitle = item.title
        defer { activeDownloadID = nil }
        let worker = downloadWorker; process = worker; activity = .download; event = .preparing
        let stage = try sessionStaging()
        let token = UUID(); downloadToken = token
        defer { downloadToken = nil }
        do {
            let source = try await worker.download(binary: component, account: account, password: password, id: item.id, staging: stage, keepAlive: true, expectedBytes: item.bytes) { [weak self] event in
                Task { @MainActor in
                    guard let self, self.process === worker, self.downloadToken == token, self.activity == .download else { return }
                    self.event = event
                    if event == .guardCode || event == .mobileApproval { self.authenticationRequired = true }
                }
            }
            try Task.checkCancellation()
            connectionReady = true; connectionError = nil
            activity = .importing
            let storage = self.storage
            let importer = Task.detached(priority: .utility) { try storage.importProject(from: source, item: item, consumeStagedFiles: true) }
            let imported = try await withTaskCancellationHandler(operation: { try await importer.value }, onCancel: { importer.cancel() })
            markDownloaded(item.id); authenticationRequired = false
            // Publish complete imports even when cancellation arrives just after the atomic rename.
            await onImported(storage.library)
            return imported
        } catch {
            await discardSession()
            throw error
        }
    }

    func submitGuard(_ code: String) -> Bool {
        guard waitingForGuard else { return false }
        if connecting {
            if downloadWorker.submitGuardCode(code) { connectionEvent = .signingIn; return true }
            return false
        }
        if process?.submitGuardCode(code) == true { event = .signingIn; return true }
        return false
    }
    func cancel() {
        guard busy else { return }
        cancelling = true; process?.cancel(); job?.cancel()
    }
    func shutdown() async {
        cancelConnection(); cancel(); installedJob?.cancel()
        await connectionJob?.value; await job?.value; await installedJob?.value
        await discardSession()
    }
    private func finish() {
        activity = .idle; cancelling = false; job = nil
        if !authenticationRequired { resumePendingDownload() }
    }
    private func record(_ failure: Error) {
        guard !(failure is CancellationError), !Task.isCancelled else { return }
        error = (failure as? WorkshopFailure)?.localizedDescription ?? "无法完成文件操作，请检查磁盘空间与文件夹权限。"
    }
}
