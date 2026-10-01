import SwiftUI

/// Immutable card inputs keep unrelated progress updates out of cover/layout work.
struct WorkshopCard: View, Equatable {
    let item: WorkshopItem
    let state: WorkshopModel.CardState
    let locked: Bool
    let detailsLocked: Bool
    let classification: String
    var progress: WorkshopDownloadProgress? = nil
    let showDetails: () -> Void
    let download: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.scenePhase) private var scenePhase
    @State private var hovered = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.state == rhs.state && lhs.locked == rhs.locked && lhs.detailsLocked == rhs.detailsLocked
            && lhs.classification == rhs.classification && lhs.progress == rhs.progress
    }
    var body: some View {
        VStack(spacing: 7) {
            VStack(alignment: .leading, spacing: 8) {
                Button(action: showDetails) {
                    VStack(alignment: .leading, spacing: 8) {
                        LibraryCover(source: .remote(item.previewURL), symbol: "photo")
                            .scaleEffect(hovered && !reduced ? 1.025 : 1)
                            .aspectRatio(16 / 9, contentMode: .fit).clipped()
                        Text(item.title).font(.callout.weight(.medium)).lineLimit(2)
                            .frame(height: 36, alignment: .topLeading).padding(.horizontal, 10)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(GalleryPressStyle()).disabled(detailsLocked)
                Group {
                    if state == .downloading {
                        WorkshopTransferView(progress: progress ?? .init(fraction: nil), compact: true)
                            .accessibilityIdentifier("workshop.card.progress." + item.id)
                            .accessibilityLabel(Text(item.title) + Text(", ") + Text("Steam 下载进度与速度"))
                    } else {
                        Text(classification).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(height: 30).padding(.horizontal, 10).padding(.bottom, 10)
            }.frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(hovered ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.10))
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(hovered && !reduced ? 0.12 : 0), radius: 6, y: 2)
                .contentShape(RoundedRectangle(cornerRadius: 12))
                .onHover { hovered = $0 }
                .animation(reduced ? nil : .easeOut(duration: 0.16), value: hovered)
                .onDisappear { hovered = false }
            Button(action: download) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .contentTransition(.symbolEffect(.replace))
                        // Finite feedback on actual byte samples; no perpetual animation timer.
                        .symbolEffect(.pulse, options: .nonRepeating, value: progress?.receivedBytes ?? 0)
                        .symbolEffectsRemoved(reduced || scenePhase != .active || state != .downloading)
                    Text(LocalizedStringKey(buttonTitle))
                }.font(.callout.weight(.medium)).frame(maxWidth: .infinity).frame(height: 30)
                    .animation(reduced ? nil : .easeOut(duration: 0.18), value: state)
            }.buttonStyle(WorkshopDownloadStyle(completed: state == .downloaded, active: state == .downloading || state == .waiting || state == .importing))
                .disabled(locked || (state != .available && state != .failed))
                .accessibilityIdentifier("workshop.card.download." + item.id)
        }
    }
    private var buttonTitle: String {
        switch state {
        case .available: return "下载"
        case .failed: return "重试下载"
        case .downloaded: return "已下载"
        case .queued: return "排队中"
        case .waiting: return "等待连接…"
        case .downloading: return "下载中…"
        case .importing: return "正在加入…"
        case .unsupported: return "暂不支持"
        }
    }
    private var symbol: String {
        switch state {
        case .downloaded: return "checkmark.circle.fill"
        case .waiting, .queued: return "clock"
        case .downloading, .importing: return "arrow.down.circle.fill"
        case .unsupported: return "minus.circle"
        case .available: return "arrow.down.circle"
        case .failed: return "arrow.clockwise"
        }
    }
}

private struct WorkshopDownloadStyle: ButtonStyle {
    let completed: Bool
    let active: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(completed ? Color.green : (active || (hovered && enabled) ? Color.accentColor : Color.primary))
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(completed ? Color.green.opacity(0.10) : Color.accentColor.opacity(hovered && enabled ? 0.16 : 0.065))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(completed ? Color.green.opacity(0.22) : Color.accentColor.opacity(hovered && enabled ? 0.5 : 0.12))
                    .allowsHitTesting(false)
            }
            .opacity(!enabled && !completed && !active ? 0.6 : 1)
            .scaleEffect(configuration.isPressed && enabled && !reduced ? 0.98 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { hovered = $0 }
            .animation(reduced ? nil : .easeOut(duration: 0.14), value: hovered)
            .animation(reduced ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
    }
}
