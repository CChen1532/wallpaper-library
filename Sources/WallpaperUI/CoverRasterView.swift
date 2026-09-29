import SwiftUI
import AppKit

/// Frame changes stay in a backing layer, without invalidating the SwiftUI grid.
struct CoverRasterView: NSViewRepresentable {
    let raster: CoverRaster
    let animate: Bool
    func makeNSView(context: Context) -> AnimatedCoverNSView { AnimatedCoverNSView() }
    func updateNSView(_ view: AnimatedCoverNSView, context: Context) { view.configure(raster, animate: animate) }
    static func dismantleNSView(_ view: AnimatedCoverNSView, coordinator: ()) { view.stop() }
}

final class AnimatedCoverNSView: NSView {
    private var raster: CoverRaster?
    private var animate = false
    private var start = ProcessInfo.processInfo.systemUptime
    private(set) var frameIndex = -1
    private var playback: CoverPlaybackGroup?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ value: CoverRaster, animate: Bool) {
        guard raster !== value || self.animate != animate else { return }
        if raster !== value { raster = value; frameIndex = -1; start = ProcessInfo.processInfo.systemUptime }
        self.animate = animate
        if frameIndex < 0 || !animate { displayFrame(0) }
        updateMembership()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateMembership() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); updateMembership() }
    override func layout() {
        super.layout()
        updateMembership()
        playback?.invalidateVisibility()
    }
    private func updateMembership() {
        // Static covers need neither notification observers nor a playback timer.
        guard animate, (raster?.frames.count ?? 0) > 1, let window else {
            playback?.remove(self); playback = nil; return
        }
        let container = enclosingScrollView?.contentView ?? window.contentView ?? self
        if playback?.container === container { return }
        playback?.remove(self)
        playback = CoverPlaybackGroup.shared(for: container)
        playback?.add(self)
    }
    var isCoverVisible: Bool {
        window != nil && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty
    }
    func advanceFrame(at time: TimeInterval) {
        guard animate, let raster else { return }
        displayFrame(raster.frameIndex(at: time - start))
    }
    private func displayFrame(_ index: Int) {
        guard index != frameIndex, let raster else { return }
        frameIndex = index
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.contents = raster.frames[index]
        CATransaction.commit()
    }
    func stop() {
        playback?.remove(self); playback = nil
        raster = nil; layer?.contents = nil; frameIndex = -1
    }
}

/// One scheduler and one scroll observer per container, not per card.
/// Scroll notifications only update a deadline; geometry is checked once after settling.
@MainActor
final class CoverPlaybackGroup {
    private static var lastScrollTime: TimeInterval = -.infinity
    private static let groups = NSMapTable<NSView, CoverPlaybackGroup>.weakToStrongObjects()
    static func shared(for container: NSView) -> CoverPlaybackGroup {
        if let group = groups.object(forKey: container) { return group }
        let group = CoverPlaybackGroup(container: container)
        if ProcessInfo.processInfo.systemUptime - lastScrollTime < 0.14 { group.pauseForScroll() }
        groups.setObject(group, forKey: container)
        return group
    }
    static func scrollMoved() {
        lastScrollTime = ProcessInfo.processInfo.systemUptime
        // SwiftUI's native scrolling implementation need not expose an NSScrollView.
        for group in groups.objectEnumerator()?.allObjects as? [CoverPlaybackGroup] ?? [] {
            group.pauseForScroll()
        }
    }
    weak var container: NSView?
    private let views = NSHashTable<AnimatedCoverNSView>.weakObjects()
    private var visible = NSHashTable<AnimatedCoverNSView>.weakObjects()
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var visibilityDirty = true
    private var refreshScheduled = false
    private var scrollUntil: TimeInterval = 0
    private var lastBounds: NSRect
    private let isActive: () -> Bool
    private let now: () -> TimeInterval
    private(set) var visibilityPasses = 0
    var hasTimer: Bool { timer != nil }
    var visibleCount: Int { visible.allObjects.count }
    var memberCount: Int { views.allObjects.count }

    init(container: NSView, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         isActive: (() -> Bool)? = nil) {
        self.container = container; lastBounds = container.bounds; self.now = now
        self.isActive = isActive ?? { [weak container] in
            NSApp.isActive && container?.window?.occlusionState.contains(.visible) == true
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification] {
            let object: AnyObject? = name == NSApplication.didBecomeActiveNotification
                || name == NSApplication.didResignActiveNotification ? nil : container.window
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidateVisibility() }
            })
        }
        if let clip = container as? NSClipView {
            clip.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.boundsChanged() }
            })
        }
    }
    func add(_ view: AnimatedCoverNSView) { views.add(view); invalidateVisibility() }
    func remove(_ view: AnimatedCoverNSView) {
        views.remove(view); visible.remove(view)
        if views.allObjects.isEmpty {
            timer?.invalidate(); timer = nil
            observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
            if let container, Self.groups.object(forKey: container) === self { Self.groups.removeObject(forKey: container) }
        } else { invalidateVisibility() }
    }
    func invalidateVisibility() {
        visibilityDirty = true
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.tick()
        }
    }
    private func boundsChanged() {
        guard let container, container.bounds != lastBounds else { return }
        lastBounds = container.bounds
        pauseForScroll()
    }
    func pauseForScroll() {
        scrollUntil = now() + 0.14
        visibilityDirty = true
        // Retain the last frame throughout wheel, trackpad inertia and scrollbar movement.
        if isActive() { startTimer() }
    }
    func tick() {
        guard isActive(), !views.allObjects.isEmpty else {
            visible.removeAllObjects(); visibilityDirty = true
            timer?.invalidate(); timer = nil; return
        }
        let time = now()
        guard time >= scrollUntil else { return }
        if visibilityDirty {
            visibilityDirty = false; visibilityPasses += 1
            visible.removeAllObjects()
            for view in views.allObjects where view.isCoverVisible { visible.add(view) }
        }
        let activeViews = visible.allObjects
        guard !activeViews.isEmpty else { timer?.invalidate(); timer = nil; return }
        startTimer()
        for view in activeViews { view.advanceFrame(at: time) }
    }
    private func startTimer() {
        guard timer == nil, !views.allObjects.isEmpty else { return }
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    deinit { timer?.invalidate(); observers.forEach(NotificationCenter.default.removeObserver) }
}

/// Report offsets without publishing them as SwiftUI state or rebuilding the grid.
struct CoverScrollPerformance: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: CGPoint.self) { $0.contentOffset } action: { _, _ in
                CoverPlaybackGroup.scrollMoved()
            }
        } else {
            content // NSClipView notifications cover the older AppKit scroll implementation.
        }
    }
}
