import SwiftUI

/// Shared by the current card, fixed task strip, queue and details.
struct WorkshopTransferView: View {
    let progress: WorkshopDownloadProgress
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.scenePhase) private var scenePhase
    private var motion: Animation? { reduced || scenePhase != .active ? nil : .linear(duration: 0.35) }
    private var accessibilityValue: Text {
        var value = progress.fraction.map { Text($0, format: .percent.precision(.fractionLength(0))) } ?? Text("正在下载…")
        if progress.estimated { value = Text("估算") + Text(" ") + value }
        let speed: Text
        if let rate = progress.bytesPerSecond, rate.isFinite, rate >= 0 {
            speed = Text(ByteCountFormatter.string(fromByteCount: Int64(min(rate, Double(Int64.max / 2))), countStyle: .file) + "/s")
        } else { speed = Text("正在测速…") }
        return value + Text(", ") + speed
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            WorkshopProgressTrack(fraction: progress.fraction, motion: motion)
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                if let fraction = progress.fraction {
                    if progress.estimated { Text("估算").foregroundStyle(.secondary) }
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .contentTransition(.numericText())
                        .animation(motion, value: fraction)
                } else { Text("正在下载…") }
                Spacer(minLength: 0)
                if let speed = progress.bytesPerSecond, speed.isFinite, speed >= 0 {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(min(speed, Double(Int64.max / 2))), countStyle: .file) + "/s")
                        .contentTransition(.numericText())
                        .animation(motion, value: speed)
                } else { Text("正在测速…") }
            }.font(compact ? .caption2 : .caption).monospacedDigit().foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .help("速度统计当前 Steam 下载进程的网络接收量；估算进度可能因压缩和协议开销而变化。")
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Steam 下载进度与速度"))
            .accessibilityValue(accessibilityValue)
    }
}

/// Only the fill scales: progress updates never animate card or scroll geometry.
private struct WorkshopProgressTrack: View {
    let fraction: Double?
    let motion: Animation?
    @Environment(\.accessibilityReduceMotion) private var reduced

    var body: some View {
        Group {
            if let fraction, fraction.isFinite {
                let value = min(1, max(0, fraction))
                Capsule().fill(Color.primary.opacity(0.10))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.accentColor.gradient)
                            .scaleEffect(x: value, y: 1, anchor: .leading)
                            .animation(motion, value: value)
                    }
                    .clipShape(Capsule())
            } else if reduced {
                Capsule().fill(Color.primary.opacity(0.10))
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }.frame(height: 6)
    }
}
