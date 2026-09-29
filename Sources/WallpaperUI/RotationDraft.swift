import Foundation

/// Editing stays local until the user explicitly applies the draft.
struct RotationDraft {
    var minutesText = "60"
    var mode = "rand"
    private var initialMinutes = "60"
    private var initialMode = "rand"
    var minutes: Int? { Self.parseMinutes(minutesText) }
    var isEdited: Bool { minutesText != initialMinutes || mode != initialMode }
    static func parseMinutes(_ text: String) -> Int? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4 else { return nil }
        var value = 0
        for character in text {
            guard character.unicodeScalars.count == 1, character.unicodeScalars.first?.properties.numericType == .decimal,
                  let digit = character.wholeNumberValue, (0...9).contains(digit) else { return nil }
            value = value * 10 + digit
        }
        return (1...1440).contains(value) ? value : nil
    }
    mutating func sync(interval: Int?, mode: String?, supportedModes: [String]) {
        minutesText = String(min(1440, max(1, (interval ?? 3600) / 60)))
        self.mode = supportedModes.first(where: { $0 == mode }) ?? supportedModes.first ?? "rand"
        initialMinutes = minutesText; initialMode = self.mode
    }
    func matches(interval: Int?, mode: String?) -> Bool {
        guard let minutes else { return false }
        return interval == minutes * 60 && mode == self.mode
    }
}
