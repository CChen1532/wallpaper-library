import SwiftUI

/// Shared by the current card, fixed task strip, queue and details.
struct WorkshopTransferView: View {
    let progress: WorkshopDownloadProgress
    var compact = false
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
            if let fraction = progress.fraction {
                ProgressView(value: fraction).progressViewStyle(.linear)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack(spacing: 6) {
                if let fraction = progress.fraction {
                    if progress.estimated { Text("估算").foregroundStyle(.secondary) }
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                } else { Text("正在下载…") }
                Spacer(minLength: 0)
                if let speed = progress.bytesPerSecond, speed.isFinite, speed >= 0 {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(min(speed, Double(Int64.max / 2))), countStyle: .file) + "/s")
                } else { Text("正在测速…") }
            }.font(compact ? .caption2 : .caption).monospacedDigit().foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .help("速度统计当前 Steam 下载进程的网络接收量；估算进度可能因压缩和协议开销而变化。")
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Steam 下载进度与速度"))
            .accessibilityValue(accessibilityValue)
    }
}
