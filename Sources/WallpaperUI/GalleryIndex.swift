import Foundation

protocol GallerySearchable {
    var id: String { get }
    var title: String { get }
    var searchTerms: [String] { get }
}

/// Rebuilt only when catalog data changes, not on selection or layout updates.
struct GalleryIndex<Item: GallerySearchable> {
    private struct Record {
        let item: Item
        let id: String
        let title: String
        let terms: [String]
    }
    private let records: [Record]

    init(_ items: [Item] = []) {
        records = items.map { Record(item: $0, id: $0.id, title: $0.title, terms: $0.searchTerms) }
            .sorted { $0.title == $1.title ? $0.id < $1.id : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func matching(_ query: String) -> [Item] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return records.compactMap { record in
            query.isEmpty || record.terms.contains { $0.localizedCaseInsensitiveContains(query) } ? record.item : nil
        }
    }
}
