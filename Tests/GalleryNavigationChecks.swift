import Foundation

@main struct GalleryNavigationChecks {
    static func main() {
        var checks = 0
        func check(_ result: Bool, _ label: String) {
            precondition(result, label); checks += 1; print("PASS: \(label)")
        }
        typealias G = GalleryNavigation
        check(G.targetIndex(from: nil, count: 0, columns: 3, direction: .down) == nil, "empty grid has no target")
        check(G.targetIndex(from: nil, count: 8, columns: 3, direction: .right) == 0, "initial move selects first rather than skipping it")
        check(G.targetIndex(from: 99, count: 8, columns: 3, direction: .down) == 0, "stale selection resolves to first result")
        check(G.targetIndex(from: 2, count: 8, columns: 3, direction: .up) == 2, "up on first row preserves column")
        check(G.targetIndex(from: 6, count: 8, columns: 3, direction: .down) == 6, "down on last row does not jump sideways")
        check(G.targetIndex(from: 5, count: 8, columns: 3, direction: .down) == 7, "short last row clamps to last available card")
        check(G.targetIndex(from: 7, count: 8, columns: 3, direction: .up) == 4, "up retains column")
        check(G.targetIndex(from: 1, count: 8, columns: 4, direction: .down) == 5, "resized grid uses new column count")
        check(G.targetIndex(from: 0, count: 8, columns: 3, direction: .left) == 0, "left clamps at start")
        check(G.targetIndex(from: 7, count: 8, columns: 3, direction: .right) == 7, "right clamps at end")
        check(G.targetIndex(from: 0, count: 1, columns: 0, direction: .down) == 0, "single card and zero columns safe")
        check(G.normalizedQuery("  海边\n") == "海边", "pasted query ignores surrounding whitespace")
        check(G.normalizedQuery(" \n\t") == "", "whitespace query restores all results")
        print("\(checks) gallery navigation checks passed")
    }
}
