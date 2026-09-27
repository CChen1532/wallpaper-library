import Foundation

private struct Item: GallerySearchable {
    let id: String
    let title: String
    let alias: String
    var searchTerms: [String] { [title, alias] }
}

@main struct GalleryIndexChecks {
    static func main() {
        var count = 0
        func check(_ result: Bool, _ label: String) {
            precondition(result, label); count += 1; print("PASS: \(label)")
        }
        let items = [Item(id: "b", title: "Wallpaper 10", alias: "10002"),
                     Item(id: "c", title: "Wallpaper 2", alias: "海边"),
                     Item(id: "a", title: "Wallpaper 2", alias: "10001")]
        let index = GalleryIndex(items)
        check(index.matching("").map(\.id) == ["a", "c", "b"], "natural ordering and stable equal-title IDs")
        check(index.matching("  WALLPAPER 2\n").map(\.id) == ["a", "c"], "case-insensitive search trims whitespace and retains order")
        check(index.matching("海边").map(\.id) == ["c"], "scene folder aliases remain searchable")
        check(index.matching("10002").map(\.id) == ["b"], "numeric material aliases remain searchable")
        check(index.matching("missing").isEmpty, "no matches produces empty result")
        let replacement = GalleryIndex([Item(id: "b", title: "Updated", alias: "new")])
        check(replacement.matching("").map(\.id) == ["b"] && replacement.matching("new").first?.title == "Updated", "replacement snapshot includes removal and metadata changes at the same ID")
        check(index.matching("10002").first?.title == "Wallpaper 10", "previous snapshot remains immutable")

        // Isolate repeated gallery ordering/filtering, not end-to-end UI FPS.
        let library = (0..<400).map { ($0 * 137) % 400 }
            .map { Item(id: String($0), title: "Wallpaper \($0)", alias: "场景\($0)") }
        let cached = GalleryIndex(library)
        var oldTimes: [Double] = [], newTimes: [Double] = []
        var checksum = 0
        func measure(_ block: () -> [Item]) -> Double {
            let start = CFAbsoluteTimeGetCurrent()
            for _ in 0..<50 { checksum += block().count }
            return (CFAbsoluteTimeGetCurrent() - start) * 1000 / 50
        }
        for round in 0..<6 {
            let old = {
                library.filter { $0.searchTerms.contains { $0.localizedCaseInsensitiveContains("Wallpaper") } }
                    .sorted { $0.title == $1.title ? $0.id < $1.id : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            }
            let current = { cached.matching("Wallpaper") }
            check(old().map(\.id) == current().map(\.id), "benchmark old/new results match round \(round)")
            if round.isMultiple(of: 2) { oldTimes.append(measure(old)); newTimes.append(measure(current)) }
            else { newTimes.append(measure(current)); oldTimes.append(measure(old)) }
        }
        print(String(format: "400-item query median: old %.3f ms, cached %.3f ms; checksum %d", oldTimes.sorted()[3], newTimes.sorted()[3], checksum))
        print("\(count) gallery index checks passed")
    }
}
