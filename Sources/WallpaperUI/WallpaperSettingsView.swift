import SwiftUI

struct WallpaperSettingsView: View {
    @AppStorage("appAppearance") private var appearance = AppAppearance.system
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
