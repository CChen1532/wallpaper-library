import Combine
import CoreFoundation
import CryptoKit
import Foundation

enum ScenePropertyValue: Equatable, Sendable {
    case boolean(Bool)
    case number(Double)
    case string(String)

    var jsonValue: Any {
        switch self {
        case .boolean(let value): value
        case .number(let value): value
        case .string(let value): value
        }
    }
}

struct ScenePropertyChoice: Equatable, Identifiable, Sendable {
    let label: String
    let value: String
    var id: String { value }
}

enum ScenePropertyKind: Equatable, Sendable {
    case boolean
    case slider(minimum: Double, maximum: Double, step: Double)
    case choice([ScenePropertyChoice])
    case color
    case textInput
}

struct ScenePropertyDefinition: Identifiable, Sendable {
    let id: String
    let label: String
    let order: Int
    let kind: ScenePropertyKind
    let sourceDefault: ScenePropertyValue
    let preferredDefault: ScenePropertyValue

    func validated(_ raw: Any) -> ScenePropertyValue? {
        switch kind {
        case .boolean:
            guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
            return .boolean(value.boolValue)
        case .slider(let minimum, let maximum, let step):
            guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            let number = value.doubleValue
            guard number.isFinite, (minimum...maximum).contains(number) else { return nil }
            let quantized = min(maximum, max(minimum, minimum + ((number - minimum) / step).rounded() * step))
            return .number(quantized)
        case .choice(let choices):
            guard let value = raw as? String, choices.contains(where: { $0.value == value }) else { return nil }
            return .string(value)
        case .color:
            guard let value = raw as? String, let normalized = Self.normalizedColor(value) else { return nil }
            return .string(normalized)
        case .textInput:
            guard let value = raw as? String, value.count <= 256,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
            return .string(value)
        }
    }

    static func normalizedColor(_ raw: String) -> String? {
        let fields = raw.split(whereSeparator: \.isWhitespace)
        guard fields.count == 3 || fields.count == 4 else { return nil }
        let values = fields.compactMap { Double($0) }
        guard values.count == fields.count, values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        return values.map { String($0) }.joined(separator: " ")
    }
}

struct ScenePropertyCatalog: Sendable {
    let properties: [ScenePropertyDefinition]
    static let empty = Self(properties: [])

    static func load(for package: URL) -> Self {
        let project = package.deletingLastPathComponent().appendingPathComponent("project.json")
        guard let values = try? project.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 1_048_576,
              let data = try? Data(contentsOf: project), data.count == size,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let general = root["general"] as? [String: Any],
              let descriptors = general["properties"] as? [String: [String: Any]] else { return .empty }
        var items: [ScenePropertyDefinition] = []
        for key in descriptors.keys.sorted() {
            if items.count >= 128 { break }
            guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,63}$"#, options: .regularExpression) != nil,
                  let descriptor = descriptors[key], let type = descriptor["type"] as? String,
                  let rawLabel = descriptor["text"] as? String,
                  let label = displayLabel(rawLabel, key: key),
                  let source = descriptor["value"] else { continue }
            let kind: ScenePropertyKind
            switch type {
            case "bool":
                kind = .boolean
            case "slider":
                guard let lower = finiteNumber(descriptor["min"]), let upper = finiteNumber(descriptor["max"]),
                      let step = finiteNumber(descriptor["step"]), lower < upper, step > 0,
                      (upper - lower) / step <= 100_000 else { continue }
                kind = .slider(minimum: lower, maximum: upper, step: step)
            case "combo":
                guard let options = descriptor["options"] as? [[String: Any]],
                      !options.isEmpty, options.count <= 64 else { continue }
                let choices = options.compactMap { option -> ScenePropertyChoice? in
                    guard let value = option["value"] as? String, value.count <= 128,
                          let raw = option["label"] as? String,
                          let label = displayLabel(raw, key: "") else { return nil }
                    return .init(label: label, value: value)
                }
                guard choices.count == options.count,
                      Set(choices.map(\.value)).count == choices.count else { continue }
                kind = .choice(choices)
            case "color":
                kind = .color
            case "textinput":
                kind = .textInput
            default:
                // HTML information, groups and external shortcuts are not editable properties.
                continue
            }
            let ordering = (descriptor["order"] as? Int) ?? (descriptor["index"] as? Int) ?? Int.max
            let probe = ScenePropertyDefinition(id: key, label: label, order: ordering, kind: kind,
                                                sourceDefault: .boolean(false), preferredDefault: .boolean(false))
            guard let original = probe.validated(source) else { continue }
            let preferred: ScenePropertyValue = key == "watermark" && original == .boolean(true)
                ? .boolean(false) : original
            items.append(.init(id: key, label: label, order: ordering, kind: kind,
                               sourceDefault: original, preferredDefault: preferred))
        }
        items.sort { left, right in
            if left.id == "watermark" { return true }
            if right.id == "watermark" { return false }
            if left.order != right.order { return left.order < right.order }
            return left.label.localizedStandardCompare(right.label) == .orderedAscending
        }
        return .init(properties: items)
    }

    private static func finiteNumber(_ raw: Any?) -> Double? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func displayLabel(_ raw: String, key: String) -> String? {
        if key == "watermark" { return "作者水印" }
        if key == "schemecolor" { return "主题颜色" }
        // Never render remote HTML, image URLs or author-supplied links in the inspector.
        if raw.range(of: #"(?i)<\s*(a|img)\b|https?://"#, options: .regularExpression) != nil { return nil }
        var text = raw.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
        for (entity, replacement) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\""] {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return String(text.prefix(80))
    }
}

struct ScenePropertyLaunch: Sendable {
    let file: URL?
    let effectiveValues: [String: ScenePropertyValue]

    static func prepare(package: URL, catalog: ScenePropertyCatalog,
                        savedData: Data?, directory: URL) throws -> Self {
        try Task.checkCancellation()
        let saved: [String: Any]
        if let savedData, savedData.count <= 64 * 1024,
           let decoded = try? JSONSerialization.jsonObject(with: savedData) as? [String: Any] {
            saved = decoded
        } else { saved = [:] }
        var effective: [String: ScenePropertyValue] = [:]
        var overrides: [String: Any] = [:]
        for property in catalog.properties {
            let value = saved[property.id].flatMap(property.validated) ?? property.preferredDefault
            effective[property.id] = value
            if value != property.sourceDefault { overrides[property.id] = value.jsonValue }
        }
        guard !overrides.isEmpty else { return .init(file: nil, effectiveValues: effective) }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let identity = package.standardizedFileURL.resolvingSymlinksInPath().path
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(key + ".json")
        let data = try JSONSerialization.data(withJSONObject: overrides, options: [.sortedKeys])
        try data.write(to: file, options: .atomic)
        return .init(file: file, effectiveValues: effective)
    }
}

/// Stored choices are keyed by the normalized scene.pkg path and validated again
/// against that scene's current project.json before launch.
@MainActor final class SceneUserPropertiesStore: ObservableObject {
    private struct CachedCatalog: Sendable {
        let modified: Date?
        let size: Int?
        let catalog: ScenePropertyCatalog
    }
    private struct CachedSavedValues {
        let data: Data?
        let values: [String: Any]
    }
    private let defaults: UserDefaults
    private let directory: URL
    private var catalogs: [String: CachedCatalog] = [:]
    private var savedCache: [String: CachedSavedValues] = [:]

    init(defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.defaults = defaults
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WallpaperUI/SceneProperties", isDirectory: true)
    }

    static func storageKey(for package: URL) -> String {
        "sceneUserProperties.v1.item." + ScenePreferencesStore.identity(for: package)
    }

    func catalog(for package: URL) -> ScenePropertyCatalog {
        let identity = ScenePreferencesStore.identity(for: package)
        let project = package.deletingLastPathComponent().appendingPathComponent("project.json")
        let attributes = try? FileManager.default.attributesOfItem(atPath: project.path)
        let modified = attributes?[.modificationDate] as? Date
        let size = attributes?[.size] as? Int
        if let cached = catalogs[identity], cached.modified == modified, cached.size == size { return cached.catalog }
        let result = ScenePropertyCatalog.load(for: package)
        catalogs[identity] = .init(modified: modified, size: size, catalog: result)
        return result
    }

    func loadCatalogInBackground(for package: URL) async -> ScenePropertyCatalog {
        let worker = Task.detached(priority: .utility) {
            let project = package.deletingLastPathComponent().appendingPathComponent("project.json")
            let attributes = try? FileManager.default.attributesOfItem(atPath: project.path)
            let modified = attributes?[.modificationDate] as? Date
            let size = attributes?[.size] as? Int
            return CachedCatalog(modified: modified, size: size,
                                 catalog: ScenePropertyCatalog.load(for: package))
        }
        let result = await worker.value
        guard !Task.isCancelled else { return .empty }
        catalogs[ScenePreferencesStore.identity(for: package)] = result
        return result.catalog
    }

    private func savedValues(for package: URL) -> [String: Any] {
        let key = Self.storageKey(for: package)
        let data = defaults.data(forKey: key)
        if let cached = savedCache[key], cached.data == data { return cached.values }
        let values: [String: Any]
        if let data, data.count <= 64 * 1024,
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            values = decoded
        } else { values = [:] }
        savedCache[key] = .init(data: data, values: values)
        return values
    }

    func value(for property: ScenePropertyDefinition, package: URL) -> ScenePropertyValue {
        // The inspector already obtained this validated definition from the
        // catalog. Re-statting project.json for every control on every phase
        // update caused synchronous I/O on the SwiftUI actor.
        if let saved = savedValues(for: package)[property.id], let valid = property.validated(saved) { return valid }
        return property.preferredDefault
    }

    func effectiveValues(for package: URL) -> [String: ScenePropertyValue] {
        effectiveValues(for: package, catalog: catalog(for: package))
    }

    func effectiveValues(for package: URL, catalog: ScenePropertyCatalog) -> [String: ScenePropertyValue] {
        let saved = savedValues(for: package)
        var result: [String: ScenePropertyValue] = [:]
        for property in catalog.properties {
            result[property.id] = saved[property.id].flatMap(property.validated) ?? property.preferredDefault
        }
        return result
    }

    func save(_ value: ScenePropertyValue, for property: ScenePropertyDefinition, package: URL) {
        guard let definition = catalog(for: package).properties.first(where: { $0.id == property.id }),
              let checked = definition.validated(value.jsonValue) else { return }
        var saved = savedValues(for: package)
        saved[property.id] = checked.jsonValue
        guard JSONSerialization.isValidJSONObject(saved),
              let data = try? JSONSerialization.data(withJSONObject: saved, options: [.sortedKeys]),
              data.count <= 64 * 1024 else { return }
        objectWillChange.send()
        let key = Self.storageKey(for: package)
        defaults.set(data, forKey: key)
        savedCache[key] = .init(data: data, values: saved)
    }

    func launch(for package: URL) throws -> ScenePropertyLaunch {
        try ScenePropertyLaunch.prepare(package: package, catalog: catalog(for: package),
                                        savedData: defaults.data(forKey: Self.storageKey(for: package)),
                                        directory: directory)
    }

    func launchInBackground(for package: URL) async throws -> ScenePropertyLaunch {
        let savedData = defaults.data(forKey: Self.storageKey(for: package))
        let directory = self.directory
        let worker = Task.detached(priority: .utility) {
            let catalog = ScenePropertyCatalog.load(for: package)
            return try ScenePropertyLaunch.prepare(package: package, catalog: catalog,
                                                   savedData: savedData, directory: directory)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value },
                                                      onCancel: { worker.cancel() })
    }
}
