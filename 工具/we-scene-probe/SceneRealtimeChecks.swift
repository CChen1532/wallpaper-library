import Foundation
import CoreVideo

func runRealtimeChecks(_ c: inout Checker) throws {
    var optional: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &optional)
    guard status == kCVReturnSuccess, let buffer = optional else {
        c.check(false, "合成BGRA缓冲区可创建")
        return
    }
    c.check(true, "合成BGRA缓冲区可创建")
    guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess,
          let base = CVPixelBufferGetBaseAddress(buffer) else {
        c.check(false, "合成BGRA缓冲区可写")
        return
    }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    let pixels: [[UInt8]] = [[10,20,30,255], [40,50,60,128],
                             [70,80,90,255], [100,110,120,64]]
    for y in 0..<2 { for x in 0..<2 {
        let offset = y * stride + x * 4
        for channel in 0..<4 { bytes[offset + channel] = pixels[y * 2 + x][channel] }
    } }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    c.check(true, "合成BGRA缓冲区可写")
    let rgba = try ScenePixelBufferDecoder.rgba(buffer, expectedWidth: 2, expectedHeight: 2)
    c.check([UInt8](rgba) == [30,20,10,255, 60,50,40,128,
                            90,80,70,255, 120,110,100,64], "实时缓冲区按行跨度转换BGRA为RGBA")
    let wrongSize: Bool
    do { _ = try ScenePixelBufferDecoder.rgba(buffer, expectedWidth: 3, expectedHeight: 2); wrongSize = false }
    catch { wrongSize = true }
    c.check(wrongSize, "实时缓冲区尺寸不匹配拒绝")
    var other: CVPixelBuffer?
    let otherStatus = CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32ARGB, nil, &other)
    if otherStatus == kCVReturnSuccess, let other {
        let wrongFormat: Bool
        do { _ = try ScenePixelBufferDecoder.rgba(other, expectedWidth: 2, expectedHeight: 2); wrongFormat = false }
        catch { wrongFormat = true }
        c.check(wrongFormat, "实时缓冲区未知像素格式拒绝")
    }
}

private actor FakeSceneFrameSource: WESceneFrameSource {
    var frames: [WESceneRealtimeSceneFrame]
    let failOnPoll: Bool
    private(set) var playCount = 0
    private(set) var closeCount = 0

    init(_ frames: [WESceneRealtimeSceneFrame], failOnPoll: Bool = false) {
        self.frames = frames
        self.failOnPoll = failOnPoll
    }
    func play() throws { playCount += 1 }
    func poll(maxDimension: Int) throws -> WESceneRealtimeSceneFrame? {
        if failOnPoll { throw ProbeError.invalid("合成帧源错误") }
        return frames.isEmpty ? nil : frames.removeFirst()
    }
    func close() { closeCount += 1 }
    func counts() -> (Int, Int) { (playCount, closeCount) }
}

private actor FakeSceneFrameSink: WESceneFrameSink {
    let failOnAccept: Bool
    private(set) var accepted = 0
    private(set) var finished = 0
    private var onAccept: (@Sendable () async -> Void)?

    init(failOnAccept: Bool = false) { self.failOnAccept = failOnAccept }
    func setOnAccept(_ action: @escaping @Sendable () async -> Void) { onAccept = action }
    func accept(_ frame: WESceneRealtimeSceneFrame) async throws {
        if failOnAccept { throw ProbeError.invalid("合成接收端错误") }
        accepted += 1
        if let onAccept { await onAccept() }
    }
    func finish() { finished += 1 }
    func counts() -> (Int, Int) { (accepted, finished) }
}

func runFrameDeliveryChecks(_ c: inout Checker) async throws {
    print("\n[8] 无窗口帧交付边界")
    let rejectsInvalidLimits: Bool
    do {
        _ = try WESceneFrameDeliveryLimits(durationSeconds: .infinity, pollHz: 5,
                                          maxDimension: 640, maxFrames: 10)
        rejectsInvalidLimits = false
    } catch { rejectsInvalidLimits = true }
    c.check(rejectsInvalidLimits, "非有限帧交付时长拒绝")
    let longLimits = try WESceneFrameDeliveryLimits(durationSeconds: 300, pollHz: 10,
                                                     maxDimension: 640, maxFrames: 3000)
    c.check(longLimits.durationSeconds == 300 && longLimits.maxFrames == 3000,
            "五分钟桌面试验帧交付边界可用")
    let rejectsOverlong = (try? WESceneFrameDeliveryLimits(durationSeconds: 300.1, pollHz: 10,
                                                           maxDimension: 640, maxFrames: 3000)) == nil
    let rejectsExtraFrame = (try? WESceneFrameDeliveryLimits(durationSeconds: 300, pollHz: 10,
                                                             maxDimension: 640, maxFrames: 3001)) == nil
    c.check(rejectsOverlong && rejectsExtraFrame, "超过五分钟或三千帧的交付限额拒绝")

    let limits = try WESceneFrameDeliveryLimits(durationSeconds: 1, pollHz: 10,
                                                maxDimension: 1, maxFrames: 2)
    func frame(width: Int = 1, height: Int = 1) -> WESceneRealtimeSceneFrame {
        let preview = WESceneStaticPreview(width: width, height: height,
            rgba: Data(repeating: 255, count: width * height * 4),
            diagnosticsJSON: Data("{}".utf8), hasRenderableContent: true)
        return WESceneRealtimeSceneFrame(preview: preview, itemSeconds: 0.1, displaySeconds: 0.1)
    }

    let source = FakeSceneFrameSource([frame(), frame(), frame()])
    let sink = FakeSceneFrameSink()
    let delivery = WESceneFrameDelivery(source: source, sink: sink, limits: limits)
    let result = try await delivery.run()
    let sourceCounts = await source.counts(), sinkCounts = await sink.counts()
    c.check(result.stopReason == .frameLimit && result.deliveredFrames == 2,
            "达到帧数上限立即结束且不交付第三帧")
    c.check(sourceCounts == (1, 1) && sinkCounts == (2, 1),
            "正常结束只关闭帧源和接收端一次")
    let rejectsSecondRun: Bool
    do { _ = try await delivery.run(); rejectsSecondRun = false }
    catch { rejectsSecondRun = true }
    c.check(rejectsSecondRun, "交付会话不可重复运行")

    let badSource = FakeSceneFrameSource([frame(width: 2)])
    let badSink = FakeSceneFrameSink()
    let badDelivery = WESceneFrameDelivery(source: badSource, sink: badSink, limits: limits)
    let rejectsOversize: Bool
    do { _ = try await badDelivery.run(); rejectsOversize = false }
    catch { rejectsOversize = true }
    let badCounts = await badSource.counts(), badSinkCounts = await badSink.counts()
    c.check(rejectsOversize && badCounts.1 == 1 && badSinkCounts == (0, 1),
            "超限像素帧拒绝且仍关闭两端")

    let stopSource = FakeSceneFrameSource([frame(), frame()])
    let stopSink = FakeSceneFrameSink()
    let stopDelivery = WESceneFrameDelivery(source: stopSource, sink: stopSink, limits: limits)
    await stopSink.setOnAccept { await stopDelivery.requestStop() }
    let stopped = try await stopDelivery.run()
    let stopCounts = await stopSource.counts(), stopSinkCounts = await stopSink.counts()
    c.check(stopped.stopReason == .requested && stopped.deliveredFrames == 1,
            "协作停止后不再交付下一帧")
    c.check(stopCounts.1 == 1 && stopSinkCounts == (1, 1),
            "协作停止同样释放帧源和接收端")

    let sourceFailure = FakeSceneFrameSource([], failOnPoll: true)
    let sourceFailureSink = FakeSceneFrameSink()
    let sourceFailureDelivery = WESceneFrameDelivery(source: sourceFailure, sink: sourceFailureSink, limits: limits)
    let sourceErrorSurfaced: Bool
    do { _ = try await sourceFailureDelivery.run(); sourceErrorSurfaced = false }
    catch { sourceErrorSurfaced = true }
    let sourceFailureCounts = await sourceFailure.counts(), sourceFailureSinkCounts = await sourceFailureSink.counts()
    c.check(sourceErrorSurfaced && sourceFailureCounts.1 == 1 && sourceFailureSinkCounts == (0, 1),
            "帧源错误向上报告且关闭两端")

    let sinkFailureSource = FakeSceneFrameSource([frame()])
    let sinkFailure = FakeSceneFrameSink(failOnAccept: true)
    let sinkFailureDelivery = WESceneFrameDelivery(source: sinkFailureSource, sink: sinkFailure, limits: limits)
    let sinkErrorSurfaced: Bool
    do { _ = try await sinkFailureDelivery.run(); sinkErrorSurfaced = false }
    catch { sinkErrorSurfaced = true }
    let sinkFailureSourceCounts = await sinkFailureSource.counts(), sinkFailureCounts = await sinkFailure.counts()
    c.check(sinkErrorSurfaced && sinkFailureSourceCounts.1 == 1 && sinkFailureCounts == (0, 1),
            "接收端错误向上报告且关闭两端")

    let durationLimits = try WESceneFrameDeliveryLimits(durationSeconds: 0.1, pollHz: 30,
                                                        maxDimension: 1, maxFrames: 2)
    let emptySource = FakeSceneFrameSource([]), emptySink = FakeSceneFrameSink()
    let elapsed = try await WESceneFrameDelivery(source: emptySource, sink: emptySink,
                                                 limits: durationLimits).run()
    let emptySourceCounts = await emptySource.counts(), emptySinkCounts = await emptySink.counts()
    c.check(elapsed.stopReason == .durationLimit && elapsed.deliveredFrames == 0 &&
            emptySourceCounts.1 == 1 && emptySinkCounts == (0, 1),
            "无新帧时也在时长上限结束并清理")

    let cancelSource = FakeSceneFrameSource([]), cancelSink = FakeSceneFrameSink()
    let cancelDelivery = WESceneFrameDelivery(source: cancelSource, sink: cancelSink, limits: limits)
    let cancelledTask = Task { try await cancelDelivery.run() }
    cancelledTask.cancel()
    let cancellationSurfaced: Bool
    do { _ = try await cancelledTask.value; cancellationSurfaced = false }
    catch is CancellationError { cancellationSurfaced = true }
    catch { cancellationSurfaced = false }
    let cancelSourceCounts = await cancelSource.counts(), cancelSinkCounts = await cancelSink.counts()
    c.check(cancellationSurfaced && cancelSourceCounts.1 == 1 && cancelSinkCounts == (0, 1),
            "任务取消向上报告且关闭两端")
}
