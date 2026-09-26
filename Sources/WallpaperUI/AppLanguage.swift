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

    static func text(_ source: String, language: AppLanguage) -> String {
        guard language == .english else { return source }
        return englishBundle?.localizedString(forKey: source, value: source, table: nil) ?? source
    }

    static func text(_ source: String, locale: Locale) -> String {
        text(source, language: locale.identifier.hasPrefix("en") ? .english : .chinese)
    }
}
