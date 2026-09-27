import AppKit
import SwiftUI
import ApplicationServices

struct WallpaperSettingsView: View {
    @Environment(\.locale) private var locale
    @EnvironmentObject private var catalog: UnifiedLibrary
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var scenePlayer: ScenePlayer
    @EnvironmentObject private var workshop: WorkshopModel
    @AppStorage("appAppearance") private var appearance = AppAppearance.system
    @AppStorage("appLanguage") private var language = AppLanguage.chinese
    @AppStorage("libraryPage") private var page = LibraryPage.library
    @AppStorage("sceneAutomaticBackdrop") private var automaticBackdrop = false
    @State private var accessibilityTrusted = false
    @State private var copiedVersionInfo = false
    @State private var removedFolder: URL?
    @State private var confirmRemoveFolder = false
    let chooseFolder: () -> Void
    let showDiagnostics: () -> Void

    var body: some View {
        Form {
            Section("外观") {
                Picker("应用外观", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
                }
            }
            Section("语言") {
                Picker("应用语言", selection: $language) {
                    Text("简体中文").tag(AppLanguage.chinese)
                    Text("English").tag(AppLanguage.english)
                }
                Text("切换后立即应用到界面，不影响正在播放的壁纸。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("素材文件夹") {
                Text("每60秒自动识别新场景与 MP4 视频，应用运行时持续检查。")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(catalog.roots, id: \.path) { root in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(root.lastPathComponent).font(.body)
                            Text(root.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        if MaterialRemoval.isBundled(root) { Text("内置").font(.caption).foregroundStyle(.secondary) }
                        else {
                            Button("移除", systemImage: "minus.circle", role: .destructive) { removedFolder = root; confirmRemoveFolder = true }
                                .disabled(model.isWorking || workshop.busy)
                                .help("从资料库移除此文件夹，保留原文件。")
                        }
                    }
                }
                if let date = catalog.lastScan { LabeledContent("上次检查", value: date.formatted(date: .omitted, time: .standard)) }
                HStack {
                    Button("添加素材文件夹", systemImage: "folder.badge.plus", action: chooseFolder)
                    Button(LocalizedStringKey(catalog.scanning ? "正在检查…" : "立即检查")) { Task { await catalog.refresh() } }
                        .disabled(catalog.scanning)
                }
                ForEach(catalog.issues, id: \.self) { issue in
                    Label(AppStrings.text(issue, locale: locale), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                Text("自动轮播仍使用原视频素材目录。其他文件夹中的视频可以单独播放。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("创意工坊") {
                Text("搜索创意工坊、通过链接添加壁纸，或同步 Steam 订阅。下载完成后自动加入资料库。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("打开创意工坊") { page = .workshop }
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
                    Text(AppStrings.text(issue, locale: locale)).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
                if let url = scenePlayer.automaticBackdropImage, let image = NSImage(contentsOf: url) {
                    LabeledContent("当前壁纸底图", value: scenePlayer.title)
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 150)
                        .accessibilityLabel(AppStrings.text("当前场景实际截图：", locale: locale) + scenePlayer.title)
                }
                if scenePlayer.isActive {
                    Text(LocalizedStringKey(scenePlayer.automaticBackdropActive ? "过渡底图已匹配；停止后可修改开关。" : "停止当前场景后可修改开关。"))
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
                    Text(AppStrings.text(issue, locale: locale)).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
                if let error = scenePlayer.error {
                    Text(AppStrings.text(error, locale: locale)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } header: {
                Text("场景 Space 切换")
            } footer: {
                Text("视频的过渡底图可在每个视频的详情栏单独设置。首次自动切换需允许本应用的辅助功能权限，以操作系统墙纸的“在所有空间中显示”开关。")
            }
            Section("关于") {
                LabeledContent(AppStrings.text("应用", locale: locale), value: "WallpaperUI")
                LabeledContent("版本", value: versionText)
                LabeledContent("构建", value: buildText)
                LabeledContent("版权", value: "© 2026 Cheng (CChen1532)")
                Text("本应用源码采用 MIT 许可；内置的 Mirage 场景运行时采用 GPL-3.0。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("打开项目主页") { openProjectHomepage() }
                    Button("在访达中显示许可文件") { revealLicenseFiles() }
                    Button("复制版本信息") { copyVersionInfo() }
                }
                if copiedVersionInfo {
                    Text("已复制版本信息").font(.callout).foregroundStyle(.secondary)
                }
                LabeledContent("辅助功能授权") { Text(LocalizedStringKey(accessibilityTrusted ? "已授权" : "未授权")) }
                Button("刷新授权状态") { accessibilityTrusted = AXIsProcessTrusted() }
                Button("显示器与运行状态", action: showDiagnostics)
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { accessibilityTrusted = AXIsProcessTrusted() }
        .confirmationDialog("从资料库移除此文件夹？", isPresented: $confirmRemoveFolder, titleVisibility: .visible) {
            Button("移除", role: .destructive) {
                guard let folder = removedFolder else { return }
                Task { if !workshop.busy { await catalog.removeFolder(folder) } }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(removedFolder?.path ?? "") + Text("\n") + Text("原文件会保留，自动检查不再扫描此来源。受影响的播放与轮播会先停止，可随时重新添加。")
        }
    }

    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? AppStrings.text("开发版", locale: locale)
        return version + AppStrings.text(" 预览版", locale: locale)
    }

    private var buildText: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
    }

    private func openProjectHomepage() {
        guard let url = URL(string: "https://github.com/CChen1532/wallpaper-library") else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealLicenseFiles() {
        guard let resources = Bundle.main.resourceURL else { return }
        let licenses = resources.appendingPathComponent("SceneRuntime/Contents/Resources/Licenses")
        let target = FileManager.default.fileExists(atPath: licenses.path) ? licenses : resources
        let workshopLicense = resources.appendingPathComponent("Licenses")
        NSWorkspace.shared.activateFileViewerSelecting([target] + (FileManager.default.fileExists(atPath: workshopLicense.path) ? [workshopLicense] : []))
    }

    private func copyVersionInfo() {
        let info = "WallpaperUI " + versionText + " (" + buildText + ") · macOS "
            + ProcessInfo.processInfo.operatingSystemVersionString
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info, forType: .string)
        copiedVersionInfo = true
    }
}
