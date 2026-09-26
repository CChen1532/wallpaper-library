import SwiftUI
import ApplicationServices

struct WallpaperSettingsView: View {
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var scenePlayer: ScenePlayer
    @AppStorage("appAppearance") private var appearance = AppAppearance.system
    @AppStorage("sceneAutomaticBackdrop") private var automaticBackdrop = false
    @State private var accessibilityTrusted = false
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
                Toggle("场景自动匹配过渡底图", isOn: $automaticBackdrop)
                    .disabled(model.isWorking || scenePlayer.isActive)
                Text("默认关闭。开启后会临时修改 macOS 系统壁纸，以场景截图承接 Space 过渡；停止、换片或退出时恢复原设置。")
                    .font(.callout).foregroundStyle(.secondary)
                if let issue = model.backdropCompatibilityIssue {
                    Text(issue).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
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
                if model.videoBackdrop.restorationPending {
                    Text("视频过渡底图的原壁纸恢复未完成。")
                        .foregroundStyle(.orange)
                    Button("恢复视频底图前的壁纸") { Task { await model.recoverVideoBackdrop() } }
                        .disabled(model.isWorking)
                }
                if let issue = model.videoBackdropIssue {
                    Text(issue).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
                if let error = scenePlayer.error {
                    Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } header: {
                Text("场景 Space 切换")
            } footer: {
                Text("视频的过渡底图可在每个视频的详情栏单独设置。首次自动切换需允许本应用的辅助功能权限，以操作系统墙纸的“在所有空间中显示”开关。")
            }
            Section("关于") {
                LabeledContent("辅助功能授权", value: accessibilityTrusted ? "已授权" : "未授权")
                Button("刷新授权状态") { accessibilityTrusted = AXIsProcessTrusted() }
                Button("显示器与运行状态", action: showDiagnostics)
                LabeledContent("版本", value: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版") + " 预览版")
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { accessibilityTrusted = AXIsProcessTrusted() }
    }
}
