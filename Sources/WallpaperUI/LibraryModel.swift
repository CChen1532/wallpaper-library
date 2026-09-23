import Foundation
import Combine

@MainActor final class LibraryModel: ObservableObject {
    @Published var items: [Wallpaper] = []
    @Published var state = PlaybackState()
    @Published var busy = false
    @Published var loading = false
    @Published var error: String?
    @Published var stateIssue: String?
    @Published var libraryIssue: String?
    @Published var selected: String?
    @Published var diagnostics: BackendDiagnostics?
    @Published var loadingDiagnostics = false
    let backend: any WallpaperBackend
    private var stateRevision = 0
    var capabilities: BackendCapabilities { backend.capabilities }
    var isWorking: Bool { busy || loading }
    var selectedWallpaper: Wallpaper? { items.first { $0.id == selected } }

    init(backend: any WallpaperBackend = PhontoBackend()) { self.backend = backend }

    func refreshLibrary() async {
        guard !isWorking else { return }
        loading = true
        defer { loading = false }
        await readLibrary()
        await readState()
    }
    private func readLibrary() async {
        do {
            items = try await backend.library()
            libraryIssue = nil
            if !items.contains(where: { $0.id == selected }) { selected = nil }
        } catch is CancellationError { return }
        catch {
            libraryIssue = error.localizedDescription
            // Do not keep actionable cards for a folder that can no longer be read.
            items = []; selected = nil
        }
    }
    func refreshState() async {
        guard !isWorking else { return }
        await readState()
    }
    private func readState() async {
        stateRevision += 1
        let revision = stateRevision
        do {
            let value = try await backend.state()
            guard revision == stateRevision else { return }
            state = value; stateIssue = nil
        } catch is CancellationError { return }
        catch {
            guard revision == stateRevision else { return }
            stateIssue = error.localizedDescription
        }
    }
    private func beginOperation() -> Bool {
        guard !isWorking else { return false }
        busy = true
        stateRevision += 1 // Invalidate an already-running poll before the mutation.
        return true
    }
    func perform(_ action: Action) async {
        guard beginOperation() else { return }
        defer { busy = false }
        do { try await backend.perform(action) }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
        await readState()
    }
    func importFiles(_ urls: [URL]) async {
        guard capabilities.canImport, beginOperation() else { return }
        defer { busy = false }
        let problems = await backend.importFiles(urls)
        if !problems.isEmpty { error = problems.joined(separator: "\n") }
        await readLibrary()
        await readState()
    }
    func trashSelected() async {
        guard capabilities.canTrash, let item = selectedWallpaper, beginOperation() else { return }
        defer { busy = false }
        do {
            try await backend.trash(item.url)
            selected = nil
            await readLibrary()
        } catch { self.error = error.localizedDescription }
        await readState()
    }
    func refreshDiagnostics() async {
        guard !loadingDiagnostics, !isWorking else { return }
        loadingDiagnostics = true
        defer { loadingDiagnostics = false }
        do { diagnostics = try await backend.diagnostics() }
        catch { self.error = error.localizedDescription }
    }
}
