import Foundation
import CoreGraphics
import ImageIO

/// No network access: hold each fetch until explicitly completed or cancelled.
private actor CoverFetchProbe {
    private(set) var starts: [URL: Int] = [:]
    private(set) var cancellations: Set<URL> = []
    private var gates: [URL: CheckedContinuation<Data?, Never>] = [:]
    func fetch(_ url: URL) async -> Data? {
        starts[url, default: 0] += 1
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: nil) }
                else { gates[url] = continuation }
            }
        }, onCancel: { Task { await self.cancel(url) } })
    }
    private func cancel(_ url: URL) {
        cancellations.insert(url)
        gates.removeValue(forKey: url)?.resume(returning: nil)
    }
    func finish(_ url: URL, data: Data) { gates.removeValue(forKey: url)?.resume(returning: data) }
}

private actor LateCoverFetchProbe {
    private(set) var cancellations = 0
    private var gates: [CheckedContinuation<Data?, Never>?] = []
    var starts: Int { gates.count }
    func fetch(_ url: URL) async -> Data? {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { gates.append($0) }
        }, onCancel: { Task { await self.recordCancellation() } })
    }
    private func recordCancellation() { cancellations += 1 }
    func finish(_ index: Int, data: Data) {
        gates[index]?.resume(returning: data); gates[index] = nil
    }
}

@main struct CoverCancellationChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            count += 1; print("PASS: " + message); fflush(stdout)
        }
        func wait(_ condition: () async -> Bool) async throws -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            return await condition()
        }
        func url(_ name: String) -> URL { URL(string: "https://images.steamusercontent.com/" + name + ".png")! }
        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        let data = encoded as Data
        let probe = CoverFetchProbe()
        let loader = CoverImageLoader(remoteFetch: { await probe.fetch($0) })
        let oldURLs = (1...4).map { url("old-\($0)") }
        var oldFinished = 0, abandonedFinished = 0
        let old = oldURLs.map { source in Task {
            let image = await loader.image(for: .remote(source), size: .card)
            oldFinished += 1; return image
        } }
        check(try await wait { await probe.starts.count == 4 }, "four slow covers occupy the bounded network slots")
        let abandonedURLs = (1...8).map { url("abandoned-\($0)") }
        let abandoned = abandonedURLs.map { source in Task {
            let image = await loader.image(for: .remote(source), size: .card)
            abandonedFinished += 1; return image
        } }
        try await Task.sleep(for: .milliseconds(100))
        check(await probe.starts.count == 4, "waiting covers cannot exceed four concurrent fetches")
        abandoned.forEach { $0.cancel() }
        check(try await wait { abandonedFinished == abandonedURLs.count }, "cancelled queued readers finish before a network slot is available")
        old.forEach { $0.cancel() }
        check(try await wait { await probe.cancellations.count == 4 }, "leaving a page cancels every unneeded in-flight cover")
        check(try await wait { oldFinished == oldURLs.count }, "cancelled active readers finish promptly")
        let visibleURL = url("now-visible")
        let visible = Task { await loader.image(for: .remote(visibleURL), size: .card) }
        check(try await wait { await probe.starts[visibleURL] == 1 }, "newly visible cover starts without waiting for old page timeouts")
        check(await probe.starts.keys.allSatisfy { !abandonedURLs.contains($0) }, "cancelled queued covers never start a download")
        await probe.finish(visibleURL, data: data)
        check(await visible.value?.image.width == 16, "newly visible cover decodes successfully after cancellations")
        var noCancelledCover = true
        for task in old + abandoned { if await task.value != nil { noCancelledCover = false } }
        check(noCancelledCover, "cancelled readers finish without publishing covers")

        // Both identical requests and different decode sizes can share one fetch.
        let sharedURL = url("shared")
        var firstFinished = false
        let first = Task {
            let image = await loader.image(for: .remote(sharedURL), size: .card)
            firstFinished = true; return image
        }
        check(try await wait { await probe.starts[sharedURL] == 1 }, "shared cover request begins")
        let remaining = Task { await loader.image(for: .remote(sharedURL), size: .card) }
        let inspector = Task { await loader.image(for: .remote(sharedURL), size: .inspector) }
        try await Task.sleep(for: .milliseconds(100))
        first.cancel()
        check(try await wait { firstFinished }, "a cancelled shared reader does not wait for other readers")
        check(await first.value == nil, "one cancelled reader returns before the shared fetch finishes")
        let sharedStarts = await probe.starts[sharedURL], sharedCancelled = await probe.cancellations.contains(sharedURL)
        check(sharedStarts == 1 && !sharedCancelled, "remaining card and inspector keep their shared fetch alive")
        await probe.finish(sharedURL, data: data)
        let remainingImage = await remaining.value, inspectorImage = await inspector.value
        check(remainingImage != nil && inspectorImage != nil, "remaining readers receive their cover after another reader cancels")
        check(await loader.image(for: .remote(sharedURL), size: .card) === remainingImage, "successful shared decode remains cached")

        let sizesURL = url("two-sizes")
        var cardFinished = false
        let small = Task {
            let image = await loader.image(for: .remote(sizesURL), size: .card)
            cardFinished = true; return image
        }
        check(try await wait { await probe.starts[sizesURL] == 1 }, "cross-size fixture starts its shared fetch")
        let large = Task { await loader.image(for: .remote(sizesURL), size: .inspector) }
        try await Task.sleep(for: .milliseconds(100))
        small.cancel()
        check(try await wait { cardFinished }, "card decoder can leave while the inspector keeps loading")
        try await Task.sleep(for: .milliseconds(100))
        let sizesStarts = await probe.starts[sizesURL], sizesCancelled = await probe.cancellations.contains(sizesURL)
        check(sizesStarts == 1 && !sizesCancelled, "cancelling the only card reader does not cancel an inspector's shared fetch")
        await probe.finish(sizesURL, data: data)
        check(await large.value != nil, "inspector receives its cover after the card leaves")

        let retryURL = oldURLs[0]
        let retry = Task { await loader.image(for: .remote(retryURL), size: .card) }
        check(try await wait { await probe.starts[retryURL] == 2 }, "returning to a cancelled cover retries immediately without a failure cooldown")
        await probe.finish(retryURL, data: data)
        check(await retry.value != nil, "returning to the previous page can display its cover")

        let lateProbe = LateCoverFetchProbe()
        let lateLoader = CoverImageLoader(remoteFetch: { await lateProbe.fetch($0) })
        let lateURL = url("late-completion")
        var leftFinished = false, replacementFinished = false
        let left = Task {
            let image = await lateLoader.image(for: .remote(lateURL))
            leftFinished = true; return image
        }
        check(try await wait { await lateProbe.starts == 1 }, "late completion fixture begins its old fetch")
        left.cancel()
        check(try await wait { leftFinished }, "reader leaves even when its underlying fetch has not acknowledged cancellation")
        check(try await wait { await lateProbe.cancellations == 1 }, "last reader cancellation reaches the underlying fetch")
        let replacement = Task {
            let image = await lateLoader.image(for: .remote(lateURL))
            replacementFinished = true; return image
        }
        check(try await wait { await lateProbe.starts == 2 }, "a new request for the same URL has its own fetch")
        await lateProbe.finish(0, data: Data("obsolete".utf8))
        await lateProbe.finish(1, data: data)
        check(try await wait { replacementFinished }, "old completion cannot remove or strand the replacement request")
        check(await replacement.value != nil, "cancelled fetch results do not poison the replacement cache")
        print("\(count) cover cancellation checks passed")
    }
}
