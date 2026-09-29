import Foundation
import Combine

/// The scheduler owns timing only. Playback always goes through LibraryModel.
@MainActor final class SelectionRotation: ObservableObject {
    enum Direction { case next, previous, random }
    @Published private(set) var active = false
    @Published private(set) var currentID: String?
    @Published private(set) var issue: String?
    @Published private(set) var switching = false
    private let items: () -> [RotationWallpaper]
    private let ready: () -> Bool
    private let play: (RotationWallpaper) async -> Bool
    private let failure: () -> String?
    private var job: Task<Void, Never>?
    private var generation = 0
    private var interval = 3600.0
    private var mode = "rand"

    init(items: @escaping () -> [RotationWallpaper], ready: @escaping () -> Bool,
         play: @escaping (RotationWallpaper) async -> Bool, failure: @escaping () -> String?) {
        self.items = items; self.ready = ready; self.play = play; self.failure = failure
    }
    func start(interval: Double, mode: String) {
        guard !switching, ready(), items().count >= 2, interval.isFinite, interval > 0,
              ["rand", "next"].contains(mode) else { return }
        stop(); currentID = nil; issue = nil; active = true
        self.interval = interval; self.mode = mode
        schedule(direction: mode == "rand" ? .random : .next)
    }
    func stop() {
        generation += 1; active = false
        // Finish an in-flight backend command; cancellation could leave a half-applied switch.
        if !switching { job?.cancel() }
    }
    func finishPendingSwitch() async { await job?.value }
    func halt(_ message: String) { issue = message; stop() }
    func advance(_ direction: Direction) {
        guard active, !switching, ready() else { return }
        generation += 1; job?.cancel(); schedule(direction: direction)
    }
    private func schedule(direction: Direction) {
        let token = generation
        job = Task { [weak self] in
            guard let self else { return }
            var direction = direction
            while self.active, self.generation == token, !Task.isCancelled {
                if !self.ready() {
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                    continue
                }
                let candidates = self.items()
                guard let item = Self.next(in: candidates, currentID: self.currentID, direction: direction) else {
                    self.issue = "轮播列表没有可用壁纸，请恢复隐藏项或重新添加。"
                    self.stop(); return
                }
                if item.id != self.currentID {
                    self.switching = true
                    let started = await self.play(item)
                    self.switching = false
                    guard self.active, self.generation == token else { return }
                    guard started else {
                        self.issue = self.failure() ?? "轮播切换失败，已停止自动切换。"
                        self.stop(); return
                    }
                    self.currentID = item.id
                }
                do { try await Task.sleep(for: .seconds(self.interval)) } catch { return }
                direction = self.mode == "rand" ? .random : .next
            }
        }
    }
    static func next(in items: [RotationWallpaper], currentID: String?, direction: Direction) -> RotationWallpaper? {
        guard !items.isEmpty else { return nil }
        switch direction {
        case .random: return items.filter { $0.id != currentID }.randomElement() ?? items.first
        case .next, .previous:
            guard let index = items.firstIndex(where: { $0.id == currentID }) else { return items.first }
            return items[(index + (direction == .next ? 1 : items.count - 1)) % items.count]
        }
    }
}
