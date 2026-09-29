import AppKit
import SwiftUI

@main struct CoverPlaybackChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, "FAIL: " + message)
            checks += 1; print("PASS: " + message)
        }
        let image = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let animated = CoverRaster(frames: [image, image], delays: [0.1, 0.1])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 2000))
        scroll.documentView = document; window.contentView = scroll
        let clip = scroll.contentView
        var time = ProcessInfo.processInfo.systemUptime
        var active = true
        let group = CoverPlaybackGroup(container: clip, now: { time }, isActive: { active })
        var cards: [AnimatedCoverNSView] = []
        for i in 0..<30 {
            let view = AnimatedCoverNSView(frame: NSRect(x: (i % 5) * 100, y: (i / 5) * 100, width: 90, height: 90))
            document.addSubview(view); view.configure(animated, animate: true)
            group.add(view); cards.append(view)
        }
        group.tick()
        check(group.memberCount == 30, "30 covers share one scheduler")
        check(group.hasTimer, "visible animations start the shared timer")
        check(group.visibleCount > 0 && group.visibleCount < 30, "offscreen covers excluded")
        let originalPasses = group.visibilityPasses
        for _ in 0..<60 { time += 1.0 / 30; group.tick() }
        check(group.visibilityPasses == originalPasses, "idle animation frames do not recalculate geometry")
        let frozenFrames = cards.map(\.frameIndex)
        for i in 1...120 {
            time += 1.0 / 120
            clip.setBoundsOrigin(NSPoint(x: 0, y: i))
            group.tick()
        }
        check(group.visibilityPasses == originalPasses, "120 scroll events perform zero visibility passes")
        check(cards.map(\.frameIndex) == frozenFrames, "covers retain their frame throughout scrolling")
        time += 0.13; group.tick()
        check(group.visibilityPasses == originalPasses, "inertia settling delay prevents premature restart")
        time += 0.02; group.tick()
        check(group.visibilityPasses == originalPasses + 1, "one visibility pass after scroll settles")
        check(group.hasTimer && group.visibleCount > 0, "visible animation resumes after scrolling")
        let settledFrames = cards.map(\.frameIndex)
        time += 0.1; group.tick()
        check(cards.map(\.frameIndex) != settledFrames, "resumed timer advances actual backing frames")
        let resumedPasses = group.visibilityPasses
        for _ in 0..<50 { group.invalidateVisibility() }
        group.tick()
        check(group.visibilityPasses == resumedPasses + 1, "layout invalidations coalesce into one pass")
        group.pauseForScroll(); time += 0.10; group.pauseForScroll(); time += 0.10; group.tick()
        check(group.visibilityPasses == resumedPasses + 1, "successive wheel events extend the pause deadline")
        time += 0.05; group.tick()
        check(group.visibilityPasses == resumedPasses + 2, "SwiftUI scroll offset signal also resumes correctly")
        active = false; group.tick()
        check(!group.hasTimer && group.visibleCount == 0, "background state stops timer and visible work")
        active = true; group.tick()
        check(group.hasTimer, "foreground state resumes eligible covers")
        for view in cards { view.isHidden = true }
        group.invalidateVisibility(); group.tick()
        check(!group.hasTimer, "all hidden covers stop the timer")
        for view in cards { view.isHidden = false }
        group.invalidateVisibility(); group.tick()
        check(group.hasTimer, "revealed covers resume")
        for view in cards { group.remove(view); view.stop() }
        check(group.memberCount == 0 && !group.hasTimer, "last member teardown cancels scheduler")
        let shared1 = CoverPlaybackGroup.shared(for: clip)
        let shared2 = CoverPlaybackGroup.shared(for: clip)
        check(shared1 === shared2, "same scroll container reuses scheduler")
        let view = cards[0]
        view.configure(animated, animate: false)
        check(view.frameIndex == 0, "Reduce Motion keeps the first frame")
        view.configure(CoverRaster(image), animate: true)
        check(view.frameIndex == 0, "static covers display without animation")
        check(CoverPlaybackGroup.shared(for: clip).memberCount == 0, "static and reduced-motion covers have no observers or timer membership")
        view.stop()
        check(view.frameIndex == -1 && view.layer?.contents == nil, "dismantled cover clears backing contents")
        // Only geometry and notification delivery are benchmarked; no desktop window is ordered front.
        let benchmark = CoverPlaybackGroup(container: clip, now: { time }, isActive: { active })
        for card in cards { benchmark.add(card) }
        benchmark.tick()
        let passes = benchmark.visibilityPasses
        let start = ProcessInfo.processInfo.systemUptime
        for i in 0..<10_000 { clip.setBoundsOrigin(NSPoint(x: 0, y: i % 200)); benchmark.tick() }
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        check(benchmark.visibilityPasses == passes, "10,000 moving offsets do not rescan card visibility")
        for card in cards { benchmark.remove(card) }
        print(String(format: "Scroll notification benchmark: %.2f ms / 10,000 offsets (not FPS)", elapsed))
        print("\(checks) cover playback checks passed (no visible window)")
    }
}
