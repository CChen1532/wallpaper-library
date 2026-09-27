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
    private var frameIndex = -1
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
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
        if raster !== value { raster = value; frameIndex = -1; start = ProcessInfo.processInfo.systemUptime }
        self.animate = animate
        if !animate { displayFrame(0) }
        updatePlayback()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification, NSView.boundsDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updatePlayback()
            })
        }
        enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
        updatePlayback()
    }
    override func layout() { super.layout(); updatePlayback() }
    private var shouldPlay: Bool {
        animate && (raster?.frames.count ?? 0) > 1 && NSApp.isActive
        && window?.occlusionState.contains(.visible) == true
        && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty
    }
    private func updatePlayback() {
        guard raster != nil else { return }
        if frameIndex < 0 { displayFrame(0) }
        if shouldPlay {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.tick() }
            timer.tolerance = 0.005
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else { timer?.invalidate(); timer = nil }
    }
    private func tick() {
        guard shouldPlay, let raster else { updatePlayback(); return }
        displayFrame(raster.frameIndex(at: ProcessInfo.processInfo.systemUptime - start))
    }
    private func displayFrame(_ index: Int) {
        guard index != frameIndex, let raster else { return }
        frameIndex = index
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.contents = raster.frames[index]
        CATransaction.commit()
    }
    func stop() {
        timer?.invalidate(); timer = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        raster = nil; layer?.contents = nil; frameIndex = -1
    }
    deinit { timer?.invalidate(); observers.forEach(NotificationCenter.default.removeObserver) }
}
