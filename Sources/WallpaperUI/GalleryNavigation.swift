import Foundation
import CoreGraphics

/// Shared grid rules, independent of view focus and playback state.
enum GalleryNavigation {
    enum Direction { case left, right, up, down }

    /// Subpixel motion does not need a new SwiftUI transaction. The hover
    /// spring still interpolates smoothly between these quarter-point targets.
    static func hoverOffset(at point: CGPoint, in size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        func offset(_ value: CGFloat, _ length: CGFloat) -> CGFloat {
            (min(1, max(-1, value / length * 2 - 1)) * 2.5 * 4).rounded() / 4
        }
        return CGSize(width: offset(point.x, size.width), height: offset(point.y, size.height))
    }

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
