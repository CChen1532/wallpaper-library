import Foundation

/// Builds only validated launch arguments. It never starts a renderer, so
/// preloading a selected Scene cannot compete with a playing video for GPU.
actor ScenePreparationCache {
    private struct PackageStamp: Hashable {
        let modified: Date?
        let size: UInt64?
        let fileNumber: UInt64?
        let fileSystem: UInt64?
        static func read(_ package: URL) throws -> Self {
            let attributes = try FileManager.default.attributesOfItem(atPath: package.path)
            return .init(modified: attributes[.modificationDate] as? Date,
                         size: (attributes[.size] as? NSNumber)?.uint64Value,
                         fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                         fileSystem: (attributes[.systemNumber] as? NSNumber)?.uint64Value)
        }
    }
    private struct Key: Hashable {
        let package: String
        let title: String
        let stamp: PackageStamp
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
        let stamp = try PackageStamp.read(package)
        let key = Key(package: package.standardizedFileURL.path, title: title, stamp: stamp,
                      expectedBytes: expectedBytes, runtime: runtimeURL.standardizedFileURL.path,
                      displayID: displayID, preferences: preferences)
        if let cached = ready[key] { return cached }
        if let task = pending[key] {
            let result = try await task.value
            try validatePreparedPackage(package, stamp: stamp)
            return result
        }
        let task = Task.detached(priority: .utility) {
            try SceneLaunchConfiguration.prepare(runtimeURL: runtimeURL, root: root, name: name,
                                                 title: title, expectedBytes: expectedBytes,
                                                 displayID: displayID, preferences: preferences)
        }
        pending[key] = task
        do {
            let result = try await task.value
            try validatePreparedPackage(package, stamp: stamp)
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

    private func validatePreparedPackage(_ package: URL, stamp: PackageStamp) throws {
        try Task.checkCancellation()
        // A replacement during background preparation cannot publish an old launch.
        guard try PackageStamp.read(package) == stamp else {
            throw BackendError.message("场景包已变化，请刷新场景目录")
        }
    }
}
