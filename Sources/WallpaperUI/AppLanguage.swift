import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case chinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }
}

/// String values built at runtime need an explicit lookup; SwiftUI only
/// localizes literal LocalizedStringKey values from the locale environment.
enum AppStrings {
    private static let englishBundle = Bundle(path: Bundle.main.path(forResource: "en", ofType: "lproj") ?? "")

    /// 整张英文本地化表。既用于精确查找，也用于「前缀 + 运行时内容」这类拼接消息。
    private static let englishTable: [String: String] = {
        guard let path = englishBundle?.path(forResource: "Localizable", ofType: "strings"),
              let table = NSDictionary(contentsOfFile: path) as? [String: String] else { return [:] }
        return table
    }()

    /// 只有以这些标点结尾的条目才允许前缀匹配，
    /// 避免把「停止」这类短词误当成更长句子的前缀。
    private static let prefixFriendlyEndings = ["：", "。", "（", "；"]

    static func text(_ source: String, language: AppLanguage) -> String {
        guard language == .english, !source.isEmpty else { return source }
        if let exact = englishTable[source] { return exact }
        if let formatted = unitFormatted(source) { return formatted }
        if let match = longestPrefixMatch(for: source) {
            return match.value + String(source.dropFirst(match.key.count))
        }
        return englishBundle?.localizedString(forKey: source, value: source, table: nil) ?? source
    }

    /// 「5 分钟」「90 秒」这类由运行时代码拼出的数值 + 单位。
    private static func unitFormatted(_ source: String) -> String? {
        let pattern = #"^(\d+) (分钟|秒)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let numberRange = Range(match.range(at: 1), in: source),
              let unitRange = Range(match.range(at: 2), in: source),
              let value = Double(source[numberRange]) else { return nil }
        let template = String(source[unitRange]) == "分钟" ? "%.0f 分钟" : "%.0f 秒"
        return String(format: englishTable[template] ?? template, value)
    }

    private static func longestPrefixMatch(for source: String) -> (key: String, value: String)? {
        var best: (key: String, value: String)?
        for (key, value) in englishTable where key.count < source.count && source.hasPrefix(key) {
            guard prefixFriendlyEndings.contains(where: { key.hasSuffix($0) }) else { continue }
            if best == nil || key.count > best!.key.count { best = (key, value) }
        }
        return best
    }

    static func text(_ source: String, locale: Locale) -> String {
        text(source, language: locale.identifier.hasPrefix("en") ? .english : .chinese)
    }
}
