import SwiftUI
import AppKit

/// Visual building blocks for the immersive gallery: a blurred ambient
/// backdrop, a hero spotlight, poster cards and floating glass surfaces.
/// All animations are interaction-driven; nothing runs a frame loop.

/// Rounded translucent surface shared by the inspector, dock and banners.
struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat = 16
    var material: Material = .regularMaterial
    func body(content: Content) -> some View {
        content
            .background(material, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.14), radius: 18, x: 0, y: 8)
    }
}

extension View {
    func glassSurface(cornerRadius: CGFloat = 16, material: Material = .regularMaterial) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, material: material))
    }
}

/// Full-bleed, heavily blurred copy of the spotlighted wallpaper. A window
/// colored wash on top keeps text legible in both light and dark appearance.
struct AmbientBackdrop: View {
    let source: CoverSource?
    let identity: String
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let source {
                LibraryCover(source: source, symbol: "photo", size: .inspector)
                    .id(identity)
                    .transition(.opacity)
                    .blur(radius: 70, opaque: true)
                    .saturation(1.35)
                    .opacity(0.55)
            }
            Color(nsColor: .windowBackgroundColor).opacity(0.45)
        }
        .animation(.easeInOut(duration: reduced ? 0.1 : 0.6), value: identity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Large spotlight for the selected, playing or first wallpaper.
struct HeroBanner<Cover: View>: View {
    let identity: String
    let eyebrow: String?
    let title: String
    let kind: String
    let kindSymbol: String
    let detail: String
    let playing: Bool
    let canPlay: Bool
    let showsDetailsButton: Bool
    let play: () -> Void
    let showDetails: () -> Void
    @ViewBuilder let cover: () -> Cover
    @Environment(\.accessibilityReduceMotion) private var reduced

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            cover()
                .modifier(ArtworkCrossfade(identity: identity))
            LinearGradient(stops: [.init(color: .clear, location: 0.35),
                                   .init(color: .black.opacity(0.72), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    if let eyebrow {
                        Label(LocalizedStringKey(eyebrow), systemImage: playing ? "waveform" : "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.white.opacity(0.85))
                            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: playing && !reduced)
                    }
                    Text(title)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                        .contentTransition(.opacity)
                    HStack(spacing: 8) {
                        Label(LocalizedStringKey(kind), systemImage: kindSymbol)
                        if !detail.isEmpty { Text("·"); Text(detail) }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                }
                .animation(LibraryMotion.selection(reduced), value: identity)
                Spacer(minLength: 12)
                HStack(spacing: 10) {
                    if showsDetailsButton {
                        Button(action: showDetails) {
                            Label("查看详情", systemImage: "slider.horizontal.3")
                                .padding(.horizontal, 4).padding(.vertical, 2)
                        }
                        .buttonStyle(.bordered).controlSize(.large).tint(.white)
                    }
                    Button(action: play) {
                        Label("设为壁纸", systemImage: "play.fill")
                            .padding(.horizontal, 6).padding(.vertical, 2)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!canPlay)
                }
            }
            .padding(24)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 24, x: 0, y: 12)
        .accessibilityElement(children: .contain)
    }
}

/// Poster-style card: artwork fills the card, caption sits on a gradient.
struct PosterCard<Cover: View>: View {
    @Environment(\.locale) private var locale
    let title: String
    let subtitle: String
    let badge: String
    let selected: Bool
    let playing: Bool
    let warning: Bool
    let accessibilityKind: String
    let playbackStatus: String?
    var selecting = false
    let action: () -> Void
    @ViewBuilder let cover: () -> Cover
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let radius: CGFloat = 14
    private var badgeIcon: String { playing ? "waveform" : accessibilityKind == "视频壁纸" ? "play.fill" : "square.3.layers.3d" }
    private var badgeText: String { playing ? (playbackStatus ?? "桌面播放中") : badge }
    private var accessibilityStatus: String {
        let selection = AppStrings.text(selected ? "已选择" : "未选择", locale: locale)
        guard playing else { return selection }
        return selection + ", " + AppStrings.text(playbackStatus ?? "正在桌面播放", locale: locale)
    }

    var body: some View {
        Button(action: action) { surface }
            .buttonStyle(GalleryPressStyle())
            .focusable()
            .onHover { hovered = $0 }
            .onDisappear { hovered = false }
            .animation(LibraryMotion.feedback(reduceMotion), value: hovered)
            .animation(LibraryMotion.selection(reduceMotion), value: selected)
            .animation(nil, value: reduceMotion)
            .accessibilityLabel(Text(title + ", " + AppStrings.text(accessibilityKind, locale: locale)))
            .accessibilityValue(Text(accessibilityStatus))
            .help(title)
    }

    private var surface: some View {
        HoverArtwork(active: hovered) { cover() }
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay {
                LinearGradient(stops: [.init(color: .clear, location: 0.45),
                                       .init(color: .black.opacity(hovered ? 0.78 : 0.66), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                Label(LocalizedStringKey(badgeText), systemImage: badgeIcon)
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(playing ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.ultraThinMaterial.opacity(0.9)), in: Capsule())
                    .environment(\.colorScheme, .dark)
                    .padding(10)
            }
            .overlay(alignment: .topTrailing) { selectionMark.padding(10) }
            .overlay(alignment: .bottomLeading) { caption }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : .white.opacity(hovered ? 0.22 : 0.08),
                                  lineWidth: selected ? 2.5 : 0.5)
            }
            .shadow(color: Color.accentColor.opacity(selected ? 0.35 : 0), radius: selected ? 12 : 0)
            .shadow(color: .black.opacity(hovered ? 0.28 : 0.12), radius: hovered ? 16 : 6, x: 0, y: hovered ? 10 : 3)
            .offset(y: hovered && !reduceMotion ? -3 : 0)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    @ViewBuilder private var selectionMark: some View {
        if selected {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white).frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1.5))
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.78)))
        } else if selecting {
            Circle().fill(.black.opacity(0.25)).frame(width: 22, height: 22)
                .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1.5))
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
            HStack(spacing: 4) {
                Text(subtitle).opacity(0.75)
                if warning { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }.font(.system(size: 11))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Status dot with a soft halo while a wallpaper plays.
struct PlaybackDot: View {
    let color: Color
    let active: Bool
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .background {
                Circle().fill(color.opacity(0.3)).frame(width: 16, height: 16)
                    .opacity(active ? 1 : 0)
            }
            .accessibilityHidden(true)
    }
}
