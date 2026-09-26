import AppKit
import SwiftUI

struct VideoInspectorSettings: View {
    @Environment(\.locale) private var locale
    @EnvironmentObject private var model: LibraryModel
    @ObservedObject var store: VideoBackdropPreferencesStore
    @ObservedObject var backdrop: VideoBackdropController
    let video: Wallpaper

    private var frameLimit: Int { max(0, min(30, Int(video.duration.rounded(.down)) - 1)) }
    private var preferences: VideoBackdropPreferences { store.preferences(for: video.url) }

    private func value<Value>(_ keyPath: WritableKeyPath<VideoBackdropPreferences, Value>) -> Binding<Value> {
        let representedVideo = video.url
        return Binding(get: { store.preferences(for: representedVideo)[keyPath: keyPath] }, set: { newValue in
            var updated = store.preferences(for: representedVideo)
            updated[keyPath: keyPath] = newValue
            store.save(updated, for: representedVideo)
            Task { await model.applyVideoBackdropPreferences(for: representedVideo) }
        })
    }

    private var frameSecond: Binding<Int> {
        let representedVideo = video.url
        return Binding(get: { min(store.preferences(for: representedVideo).frameSecond, frameLimit) }, set: { newValue in
            var updated = store.preferences(for: representedVideo)
            updated.frameSecond = newValue
            store.save(updated, for: representedVideo)
            Task { await model.applyVideoBackdropPreferences(for: representedVideo) }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Space 过渡底图").font(.headline)
                Spacer()
                Text("仅此视频").font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("自动匹配静帧")
                    Spacer(minLength: 8)
                    Toggle("自动匹配静帧", isOn: value(\.enabled)).labelsHidden()
                }.padding(10).modifier(HoverHighlight())
                Divider().padding(.leading, 10)
                Stepper(value: frameSecond, in: 0...frameLimit) {
                    HStack {
                        Text("截帧时间")
                        Spacer()
                        Text("\(min(preferences.frameSecond, frameLimit)) " + AppStrings.text("秒", locale: locale)).foregroundStyle(.secondary)
                    }
                }.padding(10).modifier(HoverHighlight()).disabled(!preferences.enabled || frameLimit == 0)
            }.background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                .disabled(model.isWorking)
            Text("默认开启，可为此视频单独关闭。播放时会临时使用视频静帧作为 Space 过渡底图；停止后恢复原壁纸。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if backdrop.activePath == video.id, let url = backdrop.imageURL,
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(AppStrings.text("当前视频过渡静帧：", locale: locale) + video.title)
                Label("当前视频底图已匹配", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            if backdrop.restorationPending {
                Button("恢复原壁纸") { Task { await model.recoverVideoBackdrop() } }
                    .disabled(model.isWorking)
            }
            if let issue = model.videoBackdropIssue {
                Label(AppStrings.text(issue, locale: locale), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
