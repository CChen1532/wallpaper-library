import SwiftUI

/// Finite, interruptible UI animations. No timer or background frame loop.
enum LibraryMotion {
    static func feedback(_ reduced: Bool) -> Animation {
        reduced ? .easeOut(duration: 0.10) : .spring(response: 0.28, dampingFraction: 0.86)
    }
    static func reflow(_ reduced: Bool) -> Animation? {
        reduced ? nil : .interactiveSpring(response: 0.46, dampingFraction: 1, blendDuration: 0.08)
    }
    static func selection(_ reduced: Bool) -> Animation { .easeInOut(duration: reduced ? 0.10 : 0.20) }
    static func expansion(_ reduced: Bool) -> Animation? {
        reduced ? nil : .spring(response: 0.32, dampingFraction: 1)
    }
}

struct GalleryPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(!reduced && enabled && configuration.isPressed ? 0.985 : 1)
            .opacity(enabled && configuration.isPressed ? 0.94 : 1)
            .animation(LibraryMotion.feedback(reduced), value: configuration.isPressed)
            .animation(nil, value: reduced)
    }
}

struct HoverArtwork<Content: View>: View {
    let active: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var offset = CGSize.zero

    var body: some View {
        GeometryReader { geometry in
            content()
                .scaleEffect(active && !reduced ? 1.045 : 1)
                .offset(active && !reduced ? offset : .zero)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        guard active, !reduced, geometry.size.width > 0, geometry.size.height > 0 else { return }
                        offset = CGSize(width: min(1, max(-1, point.x / geometry.size.width * 2 - 1)) * 2.5,
                                        height: min(1, max(-1, point.y / geometry.size.height * 2 - 1)) * 2.5)
                    case .ended: offset = .zero
                    }
                }
        }
        .animation(reduced ? nil : .interactiveSpring(response: 0.22, dampingFraction: 1), value: offset)
        .animation(reduced ? nil : LibraryMotion.feedback(false), value: active)
        .animation(nil, value: reduced)
        .onChange(of: active) { _, active in if !active { offset = .zero } }
        .onChange(of: reduced) { _, _ in offset = .zero }
    }
}

/// This transition is deliberately restricted to noninteractive artwork.
struct ArtworkCrossfade: ViewModifier {
    let identity: String
    @Environment(\.accessibilityReduceMotion) private var reduced
    func body(content: Content) -> some View {
        ZStack { content.id(identity).transition(.opacity) }
            .animation(LibraryMotion.selection(reduced), value: identity)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct HoverHighlight: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(hovered && enabled ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .animation(LibraryMotion.selection(reduced), value: hovered)
            .animation(LibraryMotion.selection(reduced), value: enabled)
            .onDisappear { hovered = false }
    }
}

/// The List still owns selection, focus and keyboard navigation.
struct SidebarNavigationLabel: View {
    let title: String
    let symbol: String
    let selected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var hovered = false

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .scaleEffect(!reduced && hovered ? 1.08 : 1)
                .symbolVariant(selected ? .fill : .none)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(hovered && !selected ? 0.055 : 0))
                .padding(.horizontal, -5)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(LibraryMotion.feedback(reduced), value: hovered)
        .animation(LibraryMotion.selection(reduced), value: selected)
        .animation(nil, value: reduced)
        .onDisappear { hovered = false }
    }
}

struct LibraryCover: View {
    let source: CoverSource
    let symbol: String
    @State private var raster: CoverRaster?
    @State private var loadedSource: CoverSource?

    var body: some View {
        GeometryReader { geometry in
            if loadedSource == source, let raster {
                Image(decorative: raster.image, scale: 1).resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
            } else {
                Rectangle().fill(Color(nsColor: .quaternaryLabelColor))
                    .overlay(Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary))
            }
        }.accessibilityHidden(true)
            .task(id: source) {
                let requested = source
                let loaded = await CoverImageLoader.shared.image(for: requested)
                guard !Task.isCancelled else { return }
                raster = loaded
                loadedSource = requested
            }
    }
}
