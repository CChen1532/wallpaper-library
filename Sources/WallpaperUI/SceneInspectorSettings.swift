import SwiftUI

/// Bindings capture the represented package instead of a shared selection draft.
struct SceneInspectorSettings: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject var model: LibraryModel
    @EnvironmentObject var scenePlayer: ScenePlayer
    @ObservedObject var store: ScenePreferencesStore
    let package: URL
    @State private var showPlayback = false

    private var preferences: ScenePreferences { store.preferences(for: package) }
    private var isPlaying: Bool { model.isActiveScene(package) }
    private var pendingChanges: Bool { preferences != scenePlayer.activePreferences }

    private func value<Value>(_ keyPath: WritableKeyPath<ScenePreferences, Value>) -> Binding<Value> {
        let representedPackage = package
        return Binding(get: { store.preferences(for: representedPackage)[keyPath: keyPath] }, set: { value in
            var saved = store.preferences(for: representedPackage)
            saved[keyPath: keyPath] = value
            store.save(saved, for: representedPackage)
        })
    }

    private func toggle(_ label: String, _ keyPath: WritableKeyPath<ScenePreferences, Bool>) -> some View {
        HStack(spacing: 8) {
            Text(label)
            Spacer(minLength: 8)
            Toggle(label, isOn: value(keyPath)).labelsHidden().accessibilityLabel(label)
        }.padding(10).modifier(HoverHighlight())
    }

    private func picker<Value: Hashable, Options: View>(_ label: String,
        _ keyPath: WritableKeyPath<ScenePreferences, Value>, @ViewBuilder options: () -> Options) -> some View {
        HStack(spacing: 8) {
            Text(label)
            Spacer(minLength: 8)
            Picker(label, selection: value(keyPath), content: options)
                .labelsHidden().accessibilityLabel(label).frame(width: 112)
        }.padding(10).modifier(HoverHighlight())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("场景交互").font(.headline)
                Spacer()
                Text("仅此壁纸").font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                toggle("鼠标交互", \.mouseEnabled)
                    .help("控制此场景的视差、粒子跟随和脚本输入，效果取决于场景。")
                Divider().padding(.horizontal, 10)
                toggle("响应鼠标点击", \.mouseButtonsEnabled)
                    .disabled(!preferences.mouseEnabled)
                Divider().padding(.horizontal, 10)
                picker("采样频率", \.inputHz) {
                    Text("30 Hz").tag(30)
                    Text("60 Hz").tag(60)
                    Text("120 Hz").tag(120)
                }.disabled(!preferences.mouseEnabled)
            }.background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

            DisclosureGroup(isExpanded: Binding(get: { showPlayback }, set: { value in
                withAnimation(LibraryMotion.expansion(reduceMotion)) { showPlayback = value }
            })) {
                VStack(spacing: 0) {
                    picker("帧率上限", \.fps) {
                        Text("30 FPS").tag(30)
                        Text("60 FPS").tag(60)
                    }
                    picker("画面位置", \.cropMode) {
                        Text("自动适配").tag("auto")
                        Text("居中").tag("center")
                        Text("靠左").tag("left")
                        Text("靠右").tag("right")
                    }
                    toggle("跟随当前显示器", \.followsDisplay)
                        .help("关闭时固定在启动场景的显示器。")
                    Divider()
                    toggle("播放场景声音", \.soundEnabled)
                    toggle("音频响应", \.audioResponseEnabled)
                        .help("响应系统声音，需场景支持。首次使用可能需要系统录音权限。")
                }.background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 8).padding(.bottom, 4)
            } label: {
                Text("播放与声音").frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5).modifier(HoverHighlight())
            }
            if isPlaying && pendingChanges {
                Button("应用到此壁纸") {
                    let representedPackage = package
                    Task { await model.applyScenePreferences(for: representedPackage) }
                }.frame(maxWidth: .infinity).disabled(model.isWorking)
                    .help("重新启动正在播放的这张壁纸以应用设置。")
            }
            Text(isPlaying && !pendingChanges ? "设置已保存并应用" : "自动保存，下次播放此壁纸时生效")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .animation(LibraryMotion.selection(reduceMotion), value: isPlaying && !pendingChanges)
        }.font(.callout).toggleStyle(.switch).controlSize(.small)
    }
}
