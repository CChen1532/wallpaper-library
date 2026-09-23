import Foundation

struct WESceneCapabilityReport: Codable {
    let schemaVersion: Int
    let packageVersion: String
    let resourceInspectionAvailable: Bool
    let restrictedStaticPreviewAvailable: Bool
    let desktopScenePlayable: Bool
    let faithfulSceneRendering: Bool
    let previewFailure: String?
    let limitationCodes: [String]
    let description: String
}

extension WESceneInspection {
    /// This reports capabilities separately from resource presence and never enables desktop playback.
    public static func capabilityReport(packageData: Data, maxPreviewDimension: Int = 640) throws -> Data {
        guard (1...960).contains(maxPreviewDimension) else {
            throw ProbeError.invalid("能力评估预览最长边必须在1...960")
        }
        let resources = try SceneResourceInspector(package: parsePkg(packageData)).inspect()
        var previewAvailable = false
        var previewFailure: String?
        var codes = Set(resources.issues.map(\.code))
        do {
            let preview = try staticPreview(packageData: packageData, maxDimension: maxPreviewDimension)
            previewAvailable = preview.hasRenderableContent
            let summary = try JSONDecoder().decode(PreviewSummary.self, from: preview.diagnosticsJSON)
            codes.formUnion(summary.diagnostics.map(\.code))
        } catch {
            previewFailure = String(describing: error)
            codes.insert("restrictedPreviewUnavailable")
        }
        let report = WESceneCapabilityReport(schemaVersion: 1, packageVersion: resources.packageVersion,
            resourceInspectionAvailable: true, restrictedStaticPreviewAvailable: previewAvailable,
            desktopScenePlayable: false, faithfulSceneRendering: false,
            previewFailure: previewFailure, limitationCodes: codes.sorted(),
            description: "仅支持资源检查与可能的受限静态近似预览；未接入完整scene效果链及桌面持续呈现")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }
}
