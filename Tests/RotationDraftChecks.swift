import Foundation

@main struct RotationDraftChecks {
    static func main() {
        var count = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, "FAIL: " + message); count += 1; print("PASS: " + message)
        }
        for input in ["", "0", "-1", "1441", "1.5", "abc", "999999999999", "1 5", "²"] {
            check(RotationDraft.parseMinutes(input) == nil, "invalid interval rejected: " + input)
        }
        check(RotationDraft.parseMinutes(" 15 \n") == 15, "pasted interval trims whitespace")
        check(RotationDraft.parseMinutes("1440") == 1440, "one-day maximum accepted")
        check(RotationDraft.parseMinutes("1") == 1, "one-minute minimum accepted")
        check(RotationDraft.parseMinutes("３０") == 30, "full-width decimal digits accepted")
        check(RotationDraft.parseMinutes("١٥") == 15, "localized decimal digits accepted")
        var draft = RotationDraft()
        draft.sync(interval: 1800, mode: "next", supportedModes: ["rand", "next"])
        check(draft.minutes == 30 && draft.mode == "next" && !draft.isEdited, "draft reflects current settings")
        draft.minutesText = "120"
        check(draft.isEdited && !draft.matches(interval: 1800, mode: "next"), "editing is distinct from applied state")
        check(draft.matches(interval: 7200, mode: "next"), "backend confirmation matches submitted settings")
        draft.sync(interval: 1800, mode: "next", supportedModes: ["rand", "next"])
        check(draft.minutes == 30 && !draft.isEdited, "revert restores current values")
        draft.mode = "rand"
        check(draft.isEdited && !draft.matches(interval: 1800, mode: "next"), "mode edits also require explicit apply")
        draft.sync(interval: nil, mode: "unsupported", supportedModes: ["next"])
        check(draft.minutes == 60 && draft.mode == "next", "missing state gets safe supported defaults")
        print("\(count) rotation draft checks passed")
    }
}
