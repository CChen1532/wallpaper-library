import SwiftUI

struct WallpaperSettingsView: View {
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var scenePlayer: ScenePlayer
    @AppStorage("appAppearance") private var appearance = AppAppearance.system
    @AppStorage("sceneAutomaticBackdrop") private var automaticBackdrop = true
    let showDiagnostics: () -> Void

    var body: some View {
        Form {
            Section("外观") {
                Picker("应用外观", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("壁纸设置") {
                Text("选中壁纸后，在右侧详情栏调整播放与交互。每张壁纸单独保存。")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("自动匹配 Space 过渡底图", isOn: $automaticBackdrop)
                    .disabled(model.isWorking || scenePlayer.isActive)
                Text("播放场景时，将当前显示器各桌面的底图临时设为场景画面；停止、换片或退出时自动恢复。")
                    .font(.callout).foregroundStyle(.secondary)
                if let url = scenePlayer.automaticBackdropImage, let image = NSImage(contentsOf: url) {
                    LabeledContent("当前壁纸底图", value: scenePlayer.title)
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 150)
                        .accessibilityLabel("当前场景实际截图：" + scenePlayer.title)
                }
                if scenePlayer.isActive {
                    Text(scenePlayer.automaticBackdropActive ? "过渡底图已匹配；停止后可修改开关。" : "停止当前场景后可修改开关。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if scenePlayer.restorationPending {
                    Text("原壁纸恢复未完成，恢复记录已保留。")
                        .foregroundStyle(.orange)
                    Button("恢复原壁纸") { Task { await scenePlayer.recoverBackdrop() } }
                        .disabled(model.isWorking || scenePlayer.isActive)
                }
                if scenePlayer.recoveringBackdrop { ProgressView("正在恢复原壁纸…") }
                if let error = scenePlayer.error {
                    Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } header: {
                Text("Space 切换")
            } footer: {
                Text("每张壁纸独立截图、独立保存；换片重新截图，不复用其他壁纸底图。")
            }
            Section("关于") {
                Button("显示器与运行状态", action: showDiagnostics)
                LabeledContent("版本", value: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版") + " 预览版")
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
