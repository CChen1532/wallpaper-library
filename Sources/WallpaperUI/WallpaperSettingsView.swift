import SwiftUI

struct WallpaperSettingsView: View {
    @EnvironmentObject var model: LibraryModel
    @EnvironmentObject var scenePlayer: ScenePlayer
    @AppStorage("appAppearance") private var appearance = AppAppearance.system
    @AppStorage(ScenePreferences.Key.fps) private var fps = 30
    @AppStorage(ScenePreferences.Key.crop) private var crop = "auto"
    @AppStorage(ScenePreferences.Key.mouse) private var mouse = true
    @AppStorage(ScenePreferences.Key.buttons) private var buttons = true
    @AppStorage(ScenePreferences.Key.inputHz) private var inputHz = 60
    @AppStorage(ScenePreferences.Key.followsDisplay) private var followsDisplay = true
    @AppStorage(ScenePreferences.Key.sound) private var sound = false
    @AppStorage(ScenePreferences.Key.audioResponse) private var audioResponse = false
    let showDiagnostics: () -> Void

    private var pendingChanges: Bool {
        // Read the dynamic properties so external preference changes refresh this view.
        let requested = ScenePreferences(fps: fps, cropMode: crop, mouseEnabled: mouse,
            mouseButtonsEnabled: buttons, inputHz: inputHz, followsDisplay: followsDisplay,
            soundEnabled: sound, audioResponseEnabled: audioResponse)
        return scenePlayer.activePreferences != requested
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("外观") {
                    Picker("应用外观", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section {
                    Toggle("鼠标交互", isOn: $mouse)
                    Toggle("响应鼠标点击", isOn: $buttons).disabled(!mouse)
                    Picker("采样频率", selection: $inputHz) {
                        Text("30 Hz").tag(30)
                        Text("60 Hz").tag(60)
                        Text("120 Hz").tag(120)
                    }.disabled(!mouse)
                } header: { Text("场景交互") }
                footer: { Text("控制视差、粒子跟随和脚本交互，效果取决于场景。桌面操作不受影响。")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                Section("场景播放") {
                    Picker("帧率上限", selection: $fps) {
                        Text("30 FPS").tag(30)
                        Text("60 FPS").tag(60)
                    }
                    Picker("画面位置", selection: $crop) {
                        Text("自动适配").tag("auto")
                        Text("居中").tag("center")
                        Text("靠左").tag("left")
                        Text("靠右").tag("right")
                    }
                    Toggle("跟随当前显示器", isOn: $followsDisplay)
                        .help("开启时随焦点切换显示器；关闭时固定在启动场景的显示器。")
                }
                Section {
                    Toggle("播放场景声音", isOn: $sound)
                    Toggle("音频响应", isOn: $audioResponse)
                } header: { Text("声音") }
                footer: { Text("响应系统声音，需场景支持。首次使用可能需要系统录音权限。")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                Section {
                    Button("显示器与运行状态", action: showDiagnostics)
                    LabeledContent("版本", value: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版") + " 预览版")
                } header: { Text("关于") }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(scenePlayer.isActive && !pendingChanges ? "当前场景已使用这些设置" : "播放设置在下次播放时生效")
                        .font(.callout)
                    Text("外观立即生效。应用播放设置会重新启动当前场景。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("应用到当前场景") {
                    Task { await model.applyScenePreferences(ScenePreferences.load()) }
                }.buttonStyle(.borderedProminent)
                    .disabled(!scenePlayer.isActive || model.isWorking || !pendingChanges)
            }.padding(20)
        }
    }
}
