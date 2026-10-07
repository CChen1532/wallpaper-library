import SwiftUI
import AppKit
import AVFoundation
import CryptoKit
import ImageIO

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

/// Full-resolution artwork for the hero. Scene previews shipped with packages
/// are often small, so prefer the renderer's own capture or a real video frame.
enum HeroArtworkSource: Hashable, Sendable {
    case scene(package: URL)
    case video(URL)
}

private final class HeroImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

actor HeroArtworkLoader {
    static let shared = HeroArtworkLoader()
    static let maximumPixels = 3200
    private let cache = NSCache<NSString, HeroImageBox>()
    private var pending: [String: Task<CGImage?, Never>] = [:]
    init() { cache.countLimit = 8; cache.totalCostLimit = 256 * 1024 * 1024 }

    func image(for source: HeroArtworkSource) async -> CGImage? {
        let key: String
        switch source {
        case .scene(let package):
            guard let capture = Self.latestCapture(for: package) else { return nil }
            let modified = (try? capture.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
            key = capture.path + "|\(modified)"
        case .video(let url):
            key = url.standardizedFileURL.path
        }
        if let cached = cache.object(forKey: key as NSString) { return cached.image }
        if let task = pending[key] { return await task.value }
        let task = Task.detached(priority: .userInitiated) { () -> CGImage? in
            switch source {
            case .scene(let package): return Self.latestCapture(for: package).flatMap(Self.decode)
            case .video(let url): return await Self.frame(of: url)
            }
        }
        pending[key] = task
        let image = await task.value
        pending[key] = nil
        if let image { cache.setObject(HeroImageBox(image), forKey: key as NSString, cost: image.bytesPerRow * image.height) }
        return image
    }

    /// Newest still exported by the scene renderer for Space transitions (read-only).
    nonisolated static func latestCapture(for package: URL) -> URL? {
        let identity = package.standardizedFileURL.resolvingSymlinksInPath().path
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WallpaperUI/SpaceBackdrop/Captures/" + key, isDirectory: true)
        guard let runs = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        return runs.map { $0.appendingPathComponent("wallpaper.png") }
            .compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                      values.isRegularFile == true else { return nil }
                return (url, values.contentModificationDate ?? .distantPast)
            }
            .max { $0.1 < $1.1 }?.0
    }

    nonisolated static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceShouldCacheImmediately: true,
                       kCGImageSourceThumbnailMaxPixelSize: maximumPixels] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    nonisolated static func frame(of url: URL) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumPixels, height: maximumPixels)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let seconds = duration.isFinite ? min(3, max(0, duration * 0.1)) : 0
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }
}

/// Sharp hero image. Keeps the previous picture until the next one is decoded,
/// and never stretches a small preview: those are framed over their own blur.
struct HeroArtwork: View {
    let source: HeroArtworkSource?
    let fallback: CoverSource
    let identity: String
    @State private var image: CGImage?
    @State private var shownIdentity = ""
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduced

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Rectangle().fill(Color(nsColor: .underPageBackgroundColor))
                if let image {
                    let sharp = CGFloat(image.width) >= geometry.size.width * displayScale * 0.7
                    ZStack {
                        Image(decorative: image, scale: 1).resizable().interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .blur(radius: sharp ? 0 : 36, opaque: true)
                        if !sharp {
                            Image(decorative: image, scale: 1).resizable().interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                                .padding(.vertical, 18)
                        }
                    }
                    .id(shownIdentity)
                    .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .animation(.easeInOut(duration: reduced ? 0.1 : 0.35), value: shownIdentity)
        .accessibilityHidden(true)
        .task(id: identity) {
            let requested = identity
            var loaded: CGImage?
            if let source { loaded = await HeroArtworkLoader.shared.image(for: source) }
            if loaded == nil { loaded = await CoverImageLoader.shared.image(for: fallback, size: .hero)?.image }
            guard !Task.isCancelled, let loaded else { return }
            image = loaded
            shownIdentity = requested
        }
    }
}

/// Large spotlight for the selected, playing or first wallpaper.
struct HeroBanner: View {
    let identity: String
    let eyebrow: String?
    let eyebrowSymbol: String
    let title: String
    let kind: String
    let kindSymbol: String
    let detail: String
    let playing: Bool
    let canPlay: Bool
    let showsDetailsButton: Bool
    let artwork: HeroArtworkSource?
    let fallback: CoverSource
    let play: () -> Void
    let showDetails: () -> Void
    let shuffle: (() -> Void)?
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduced

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HeroArtwork(source: artwork, fallback: fallback, identity: identity)
            LinearGradient(stops: [.init(color: .clear, location: 0.4),
                                   .init(color: .black.opacity(0.7), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    if let eyebrow {
                        Label(LocalizedStringKey(eyebrow), systemImage: eyebrowSymbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.88))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(.black.opacity(0.28), in: Capsule())
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
                    .foregroundStyle(.white.opacity(0.8))
                }
                .animation(LibraryMotion.selection(reduced), value: identity)
                Spacer(minLength: 12)
                HStack(spacing: 10) {
                    if let shuffle {
                        Button(action: shuffle) {
                            Image(systemName: "dice").font(.system(size: 14, weight: .medium)).frame(width: 18, height: 20)
                        }
                        .buttonStyle(.bordered).controlSize(.large).tint(.white)
                        .help(AppStrings.text("换一张", locale: locale))
                        .accessibilityLabel(AppStrings.text("换一张", locale: locale))
                    }
                    if showsDetailsButton {
                        Button(action: showDetails) {
                            Label("查看详情", systemImage: "slider.horizontal.3")
                                .padding(.horizontal, 4).padding(.vertical, 2)
                        }
                        .buttonStyle(.bordered).controlSize(.large).tint(.white)
                    }
                    Button(action: play) {
                        Label(LocalizedStringKey(playing ? "正在桌面播放" : "设为壁纸"), systemImage: playing ? "checkmark" : "play.fill")
                            .padding(.horizontal, 6).padding(.vertical, 2)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!canPlay || playing)
                    .help(AppStrings.text("双击卡片也可设为壁纸", locale: locale))
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
    /// Sets the wallpaper directly: hover button and double-click.
    var quickAction: (() -> Void)? = nil
    let action: () -> Void
    @ViewBuilder let cover: () -> Cover
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let radius: CGFloat = 14
    private var showsQuickAction: Bool { quickAction != nil && hovered && !selecting && !playing }
    private var badgeIcon: String { playing ? "waveform" : accessibilityKind == "视频壁纸" ? "play.fill" : "square.3.layers.3d" }
    private var badgeText: String { playing ? (playbackStatus ?? "桌面播放中") : badge }
    private var accessibilityStatus: String {
        let selection = AppStrings.text(selected ? "已选择" : "未选择", locale: locale)
        guard playing else { return selection }
        return selection + ", " + AppStrings.text(playbackStatus ?? "正在桌面播放", locale: locale)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Button(action: action) { surface }
                .buttonStyle(GalleryPressStyle())
                .focusable()
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    if !selecting, !playing { quickAction?() }
                })
                .accessibilityLabel(Text(title + ", " + AppStrings.text(accessibilityKind, locale: locale)))
                .accessibilityValue(Text(accessibilityStatus))
                .help(quickAction == nil || selecting ? title : title + "\n" + AppStrings.text("双击卡片也可设为壁纸", locale: locale))
            if showsQuickAction, let quickAction {
                Button(action: quickAction) {
                    Image(systemName: "play.fill").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white).frame(width: 30, height: 30)
                        .background(Color.accentColor, in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                }
                .buttonStyle(GalleryPressStyle())
                .padding(10)
                .help(AppStrings.text("设为壁纸", locale: locale))
                .accessibilityLabel(AppStrings.text("设为壁纸", locale: locale))
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.7)))
            }
        }
            .offset(y: hovered && !reduceMotion ? -3 : 0)
            .onHover { hovered = $0 }
            .onDisappear { hovered = false }
            .animation(LibraryMotion.feedback(reduceMotion), value: hovered)
            .animation(LibraryMotion.selection(reduceMotion), value: selected)
            .animation(nil, value: reduceMotion)
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
        .padding(.leading, 12).padding(.trailing, quickAction == nil ? 12 : 46).padding(.bottom, 10)
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
