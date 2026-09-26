import Foundation

@main struct InspectorPerformance {
    @MainActor static func main() throws {
        let suite = "WallpaperUI.Performance." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SceneUserPropertiesStore(defaults: defaults)
        for path in CommandLine.arguments.dropFirst() {
            let package = URL(fileURLWithPath: path)
            let catalog = store.catalog(for: package)
            guard !catalog.properties.isEmpty else { continue }
            let saved = Dictionary(uniqueKeysWithValues: catalog.properties.map { ($0.id, $0.preferredDefault.jsonValue) })
            defaults.set(try JSONSerialization.data(withJSONObject: saved),
                         forKey: SceneUserPropertiesStore.storageKey(for: package))
            func individual() -> [String: ScenePropertyValue] {
                Dictionary(uniqueKeysWithValues: catalog.properties.map {
                    ($0.id, store.value(for: $0, package: package))
                })
            }
            func batch() -> [String: ScenePropertyValue] {
                store.effectiveValues(for: package, catalog: catalog)
            }
            precondition(individual() == batch())
            var individualTimes: [Double] = [], batchTimes: [Double] = []
            let iterations = 100
            for round in 0..<6 {
                for mode in round.isMultiple(of: 2) ? [0, 1] : [1, 0] {
                    let start = ContinuousClock.now
                    for _ in 0..<iterations {
                        let values = mode == 0 ? individual() : batch()
                        precondition(values.count == catalog.properties.count)
                    }
                    let duration = start.duration(to: .now).components
                    let ms = (Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15) / Double(iterations)
                    if mode == 0 { individualTimes.append(ms) } else { batchTimes.append(ms) }
                }
            }
            individualTimes.sort(); batchTimes.sort()
            print("properties=\(catalog.properties.count) individual_ms=\((individualTimes[2] + individualTimes[3]) / 2) batch_ms=\((batchTimes[2] + batchTimes[3]) / 2)")
        }
    }
}
