import Foundation
import Combine

@MainActor final class WorkshopModel: ObservableObject {
    enum Activity { case idle, lookup, component, download, importing }
    @Published var link = ""
    @Published var account: String
    @Published private(set) var item: WorkshopItem?
    @Published private(set) var activity = Activity.idle
    @Published private(set) var event = WorkshopSteamEvent.preparing
    @Published private(set) var error: String?
    @Published private(set) var component: URL?
    @Published private(set) var importedURL: URL?
    @Published private(set) var cancelling = false
    let storage: WorkshopStorage
    private var job: Task<Void, Never>?
    private var process: WorkshopSteamProcess?
    private let defaults: UserDefaults
    private let onImported: (URL) async -> Void
    private let findExisting: (String) -> URL?
    var busy: Bool { activity != .idle }
    var waitingForGuard: Bool { event == .guardCode && activity == .download && !cancelling }

    init(storage: WorkshopStorage = WorkshopStorage(), defaults: UserDefaults = .standard,
         findExisting: @escaping (String) -> URL? = { _ in nil },
         onImported: @escaping (URL) async -> Void = { _ in }) {
        self.storage = storage; self.defaults = defaults; self.onImported = onImported
        self.findExisting = findExisting
        account = defaults.string(forKey: "workshopAccount") ?? ""
        component = WorkshopComponent.locate(storage: storage, custom: defaults.string(forKey: "workshopSteamCMD"))
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
                if installed { importedURL = storage.destination(id); await onImported(storage.library) }
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

    func download(password: String) {
        guard !busy, let item, importedURL == nil else { return }
        if let existing = findExisting(item.id) { importedURL = existing; return }
        guard let component else { error = WorkshopFailure.componentMissing.localizedDescription; return }
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WorkshopSteamProcess.validCredentials(account: account, password: password) else { error = WorkshopFailure.invalidAccount.localizedDescription; return }
        defaults.set(account, forKey: "workshopAccount")
        let worker = WorkshopSteamProcess()
        process = worker; activity = .download; event = .preparing; error = nil
        job = Task {
            defer { process = nil; finish() }
            do {
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
                // A successful rename is the commit point. Even a late Cancel must publish this complete item.
                importedURL = imported
                await onImported(storage.library)
            } catch { record(error) }
        }
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
