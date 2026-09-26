import Foundation

/// Builds only validated launch arguments. It never starts a renderer, so
/// preloading a selected Scene cannot compete with a playing video for GPU.
actor ScenePreparationCache {
    private struct Key: Hashable {
        let package: String
        let title: String
        let modified: Date?
        let expectedBytes: Int64
        let runtime: String
        let displayID: UInt32
        let preferences: ScenePreferences
    }

    private var ready: [Key: SceneLaunchConfiguration] = [:]
    private var pending: [Key: Task<SceneLaunchConfiguration, Error>] = [:]
    private var order: [Key] = []

    func prepare(runtimeURL: URL, root: URL, name: String, title: String,
                 expectedBytes: Int64, displayID: UInt32,
                 preferences: ScenePreferences) async throws -> SceneLaunchConfiguration {
        try Task.checkCancellation()
        // A cache hit must not bypass package/symlink/size validation.
        let package = try SceneLaunchConfiguration.validatedPackage(root: root, name: name,
                                                                    expectedBytes: expectedBytes)
        let stamp = (try? package.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = Key(package: package.standardizedFileURL.path, title: title, modified: stamp,
                      expectedBytes: expectedBytes, runtime: runtimeURL.standardizedFileURL.path,
                      displayID: displayID, preferences: preferences)
        if let cached = ready[key] { return cached }
        if let task = pending[key] { return try await task.value }
        let task = Task.detached(priority: .utility) {
            try SceneLaunchConfiguration.prepare(runtimeURL: runtimeURL, root: root, name: name,
                                                 title: title, expectedBytes: expectedBytes,
                                                 displayID: displayID, preferences: preferences)
        }
        pending[key] = task
        do {
            let result = try await task.value
            pending[key] = nil
            ready[key] = result
            order.removeAll { $0 == key }
            order.append(key)
            while order.count > 4 {
                ready.removeValue(forKey: order.removeFirst())
            }
            return result
        } catch {
            pending[key] = nil
            throw error
        }
    }
}
