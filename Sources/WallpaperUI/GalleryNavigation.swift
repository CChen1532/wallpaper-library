import Foundation

/// Shared grid rules, independent of view focus and playback state.
enum GalleryNavigation {
    enum Direction { case left, right, up, down }

    static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func targetIndex(from index: Int?, count: Int, columns: Int, direction: Direction) -> Int? {
        guard count > 0 else { return nil }
        guard let index, (0..<count).contains(index) else { return 0 }
        let columns = max(1, columns)
        switch direction {
        case .left: return max(0, index - 1)
        case .right: return min(count - 1, index + 1)
        case .up: return index < columns ? index : index - columns
        case .down:
            // Stay in the last row; a shorter following row lands on its last card.
            guard index / columns < (count - 1) / columns else { return index }
            return min(count - 1, index + columns)
        }
    }
}
