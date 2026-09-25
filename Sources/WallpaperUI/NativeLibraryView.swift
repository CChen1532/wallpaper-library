import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WESceneCore

private enum LibraryPage: Hashable { case videos, scenes, rotation }
private struct SceneCatalogPayload: Decodable {
    struct Entry: Decodable, Identifiable {
        struct Capability: Decodable {
            let restrictedStaticPreviewAvailable: Bool
            let desktopScenePlayable: Bool
            let limitationCodes: [String]
        }
        let name: String
        let title: String?
        let packageBytes: Int64
        let capability: Capability?
        let error: String?
        var id: String { name }
    }
    let entries: [Entry]
}
struct NativeLibraryView: View {
    @EnvironmentObject var model: LibraryModel
    @EnvironmentObject var scenePlayer: ScenePlayer
    @State private var page: LibraryPage? = .scenes
    @AppStorage("sceneLibraryPath") private var savedSceneRoot = ""
    @AppStorage("sceneFPS") private var sceneFPS = 30
    @AppStorage("sceneCropMode") private var sceneCropMode = "auto"
    @State private var search = ""
    @State private var minutes = 60
    @State private var mode = "rand"
    @State private var confirmTrash = false
    @State private var showDiagnostics = false
    @State private var sceneRoot: URL?
    @State private var sceneEntries: [SceneCatalogPayload.Entry] = []
    @State private var selectedSceneName: String?
    @State private var sceneLoading = false
    @State private var sceneError: String?
    @State private var visibleSceneLimitations: [String] = []
    @State private var showSceneLimitations = false
    @State private var showScenePreview = false
    @State private var scenePreviewTitle = ""
    @State private var scenePreviewImage: NSImage?
    @State private var scenePreviewError: String?
    @State private var scenePreviewLoading = false
    @FocusState private var focusedVideo: String?
    private var filtered: [Wallpaper] { model.items.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) } }
    private var filteredScenes: [SceneCatalogPayload.Entry] {
        sceneEntries.filter { search.isEmpty || ($0.title ?? $0.name).localizedCaseInsensitiveContains(search) || $0.name.localizedCaseInsensitiveContains(search) }
    }
    private var selectedScene: SceneCatalogPayload.Entry? {
        filteredScenes.first { $0.name == selectedSceneName }
    }
    private var selectedSceneLimitations: [String] {
        guard let selectedSceneName else { return [] }
        return filteredScenes.first(where: { $0.name == selectedSceneName })?.capability?.limitationCodes ?? []
    }
    private var selectedPreviewScene: SceneCatalogPayload.Entry? {
        guard let selectedSceneName,
              let entry = filteredScenes.first(where: { $0.name == selectedSceneName }),
              entry.error == nil, entry.capability?.restrictedStaticPreviewAvailable == true,
              entry.packageBytes > 0, entry.packageBytes <= SceneStaticPreviewLoader.maxPackageBytes else { return nil }
        return entry
    }
    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section("资料库") {
                    Label("全部视频", systemImage: "film.stack").badge(model.items.count).tag(LibraryPage.videos)
                    Label("场景壁纸", systemImage: "square.3.layers.3d").badge(sceneEntries.count).tag(LibraryPage.scenes)
                }
                Section("桌面") { Label("自动轮播", systemImage: "arrow.triangle.2.circlepath").tag(LibraryPage.rotation) }
            }.listStyle(.sidebar).navigationTitle("视频壁纸")
                .navigationSplitViewColumnWidth(min: 175, ideal: 200, max: 250)
                .safeAreaInset(edge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("动态桌面壁纸", systemImage: "desktopcomputer")
                        Text("视频与场景，一次播放一个。").foregroundStyle(.secondary)
                    }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
        } detail: {
            VStack(spacing: 0) {
                if let issue = model.stateIssue { issueBanner("状态暂不可用：" + issue) }
                if let issue = model.libraryIssue { issueBanner("素材读取失败：" + issue) }
                if page == .rotation { rotationSettings }
                else if page == .scenes { sceneLibrary }
                else { videoLibrary }
                Divider(); desktopControls
            }
            .navigationTitle(page == .rotation ? "自动轮播" : page == .scenes ? "WE 场景" : "全部视频")
            .navigationSubtitle(page == .rotation ? "定时切换桌面上的视频壁纸" : page == .scenes ? "Scene 第一版 · 单引擎跟随当前视角" : "\(model.items.count) 个视频")
            .searchable(text: $search, placement: .toolbar, prompt: page == .scenes ? "搜索场景" : "搜索视频")
            .toolbar {
                ToolbarItemGroup {
                    if page == .scenes {
                        Button(action: chooseSceneDirectory) { Label("选择场景目录", systemImage: "folder.badge.plus") }.disabled(sceneLoading)
                        Button { if let sceneRoot { Task { await loadScenes(from: sceneRoot) } } } label: { Label("刷新场景", systemImage: "arrow.clockwise") }.disabled(sceneLoading || sceneRoot == nil)
                        Menu {
                          Button {
                            visibleSceneLimitations = selectedSceneLimitations
                            showSceneLimitations = true
                          } label: { Label("静态检查详情", systemImage: "info.circle") }
                          .disabled(selectedSceneLimitations.isEmpty || sceneLoading)
                          Button(action: beginScenePreview) { Label("受限静态预览", systemImage: "photo") }
                            .disabled(selectedPreviewScene == nil || sceneLoading || scenePreviewLoading)
                        } label: { Label("更多", systemImage: "ellipsis.circle") }
                    } else {
                        Button(action: importVideos) { Label("导入视频", systemImage: "plus") }.help("导入 MP4 视频").keyboardShortcut("o", modifiers: .command).disabled(model.isWorking || !model.capabilities.canImport)
                        Button { Task { await model.refreshLibrary() } } label: { Label("刷新", systemImage: "arrow.clockwise") }.help("刷新资料库").keyboardShortcut("r", modifiers: .command).disabled(model.isWorking)
                    }
                    if page != .scenes { Menu {
                        Button("打开视频文件夹", systemImage: "folder") { if let url = model.capabilities.libraryDirectory { NSWorkspace.shared.open(url) } }.disabled(model.capabilities.libraryDirectory == nil)
                        Button("显示器与运行状态", systemImage: "desktopcomputer") { showDiagnostics = true; Task { await model.refreshDiagnostics() } }
                    } label: { Label("更多", systemImage: "ellipsis.circle") }.help("更多操作") }
                }
            }
        }
        .task {
            async let videoRefresh: Void = model.refreshLibrary()
            if sceneRoot == nil {
                let initial = savedSceneRoot.isEmpty
                    ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Wallpapers2")
                    : URL(fileURLWithPath: savedSceneRoot, isDirectory: true)
                if FileManager.default.fileExists(atPath: initial.path) {
                    sceneRoot = initial
                    await loadScenes(from: initial)
                }
            }
            await videoRefresh
            syncRotationFields()
        }
        .onChange(of: page) { _, newValue in search = ""; if newValue == .rotation { syncRotationFields() } }
        .alert("操作提示", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("知道了") { model.error = nil } } message: { Text(model.error ?? "") }
        .confirmationDialog("将所选视频移入废纸篓？", isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("移入废纸篓", role: .destructive) { Task { await model.trashSelected() } }
            Button("取消", role: .cancel) {}
        } message: { Text("\(model.selectedWallpaper?.url.lastPathComponent ?? "")\n可以从废纸篓恢复。若正在播放此视频或开启了轮播，将先停止桌面播放并关闭轮播。") }
        .sheet(isPresented: $showDiagnostics) { diagnosticsSheet }
        .sheet(isPresented: $showSceneLimitations) { sceneLimitationsSheet }
        .sheet(isPresented: $showScenePreview) { scenePreviewSheet }
    }
    private var videoLibrary: some View {
        HSplitView {
            VStack(spacing: 0) {
                if model.loading { ProgressView("正在读取视频…").padding() }
                if !model.loading && filtered.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "添加你的第一段视频" : "没有匹配的视频", systemImage: "film.stack", description: Text(search.isEmpty ? "导入 MP4，让视频在桌面背景持续播放。" : "试试其他关键词。"))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 195), spacing: 16)], spacing: 20) {
                            ForEach(filtered) { item in
                                VideoCard(item: item, selected: model.selected == item.id, playing: model.stateIssue == nil && model.state.currentPath == item.id) { model.selected = item.id; focusedVideo = item.id }
                                    .focused($focusedVideo, equals: item.id)
                                    .onMoveCommand { direction in
                                        switch direction {
                                        case .left, .up: model.selectNextVideo(in: filtered.map(\.id), forward: false)
                                        case .right, .down: model.selectNextVideo(in: filtered.map(\.id), forward: true)
                                        default: return
                                        }
                                        focusedVideo = model.selected
                                    }
                            }
                        }.padding(20)
                    }
                }
            }.frame(minWidth: 370, maxWidth: .infinity, maxHeight: .infinity)
            if let item = model.selectedWallpaper { videoDetails(item).frame(minWidth: 230, idealWidth: 265, maxWidth: 310, maxHeight: .infinity) }
        }.background(Color(nsColor: .controlBackgroundColor))
    }
    private var sceneLibrary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("跟随当前 Space；跨屏切换时旧屏继续播放 1.5 秒。", systemImage: "rectangle.on.rectangle")
                .font(.callout).foregroundStyle(.secondary)
            Text("预览版：Mission Control 切换动画可能短暂露出系统壁纸；场景静音，睡眠或退出软件时停止。")
                .font(.caption).foregroundStyle(.secondary)
            if !model.sceneRuntimeAvailable { issueBanner("场景运行组件缺失，请使用包含 Scene 的完整构建。") }
            if let error = scenePlayer.error { issueBanner(error) }
            if let sceneError { issueBanner("场景读取失败：" + sceneError) }
            if sceneLoading { ProgressView("正在读取场景…") }
            if sceneRoot == nil {
                ContentUnavailableView("选择场景目录", systemImage: "square.3.layers.3d",
                    description: Text("选择包含 scene.pkg 子目录的素材文件夹，再选中场景开始播放。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !sceneLoading && sceneEntries.isEmpty && sceneError == nil {
                ContentUnavailableView("没有找到 scene.pkg", systemImage: "doc.text.magnifyingglass",
                    description: Text("请检查所选目录是否包含场景子目录。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !sceneLoading && filteredScenes.isEmpty && sceneError == nil {
                ContentUnavailableView("没有匹配的场景", systemImage: "magnifyingglass",
                    description: Text("试试场景标题或目录编号。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(filteredScenes, selection: $selectedSceneName) { item in
                        HStack(spacing: 12) {
                            SceneCover(folder: sceneRoot?.appendingPathComponent(item.name))
                                .frame(width: 112, height: 68).clipShape(RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.title ?? item.name).font(.headline).lineLimit(2)
                                Text("\(item.name) · " + ByteCountFormatter.string(fromByteCount: item.packageBytes, countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                                if scenePlayer.package == sceneRoot?.appendingPathComponent(item.name).appendingPathComponent("scene.pkg") {
                                    Label(scenePlayer.statusText, systemImage: "waveform").font(.caption).foregroundStyle(.tint)
                                } else { Text("Wallpaper Engine 场景").font(.caption).foregroundStyle(.secondary) }
                            }
                        }.padding(.vertical, 6).tag(item.name)
                    }.listStyle(.inset).frame(minWidth: 330)
                    if let item = selectedScene {
                        sceneDetails(item).frame(minWidth: 245, idealWidth: 290, maxWidth: 330)
                    }
                }
            }
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func sceneDetails(_ item: SceneCatalogPayload.Entry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SceneCover(folder: sceneRoot?.appendingPathComponent(item.name))
                    .frame(height: 165).clipShape(RoundedRectangle(cornerRadius: 9))
                Text(item.title ?? item.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                Button {
                    guard let sceneRoot else { return }
                    Task { await model.playScene(root: sceneRoot, name: item.name, title: item.title ?? item.name,
                                                  expectedBytes: item.packageBytes, fps: sceneFPS, cropMode: sceneCropMode) }
                } label: { Label("播放场景壁纸", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.isWorking || !model.sceneRuntimeAvailable || item.packageBytes <= 0 || item.packageBytes > 256 * 1024 * 1024)
                Text("开始播放会关闭视频和自动轮播。关闭窗口后可从菜单栏停止场景。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Picker("帧率上限", selection: $sceneFPS) {
                    Text("30 FPS").tag(30)
                    Text("60 FPS").tag(60)
                }
                Picker("画面位置", selection: $sceneCropMode) {
                    Text("自动适配").tag("auto")
                    Text("居中").tag("center")
                    Text("靠左").tag("left")
                    Text("靠右").tag("right")
                }
                Text("按屏幕分辨率渲染并填满桌面。修改选项后再次播放生效；自动适配会保留当前样本右侧的完整时间。")
                    .font(.caption).foregroundStyle(.secondary)
                if let sceneRoot {
                    Button("在访达中显示", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([sceneRoot.appendingPathComponent(item.name)])
                    }
                }
            }.padding(14)
        }
    }
    private var sceneLimitationsSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("场景限制详情").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { showSceneLimitations = false }.keyboardShortcut(.cancelAction)
            }
            Text("这些项目来自旧版离线静态分析器；Mirage 动态播放的实际效果请以桌面画面为准。")
                .font(.callout).foregroundStyle(.secondary)
            List(visibleSceneLimitations, id: \.self) { code in
                VStack(alignment: .leading, spacing: 3) {
                    Text(SceneLimitationLabels.title(for: code))
                    Text(code).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding(.vertical, 3)
            }.listStyle(.inset)
        }.padding(20).frame(minWidth: 460, minHeight: 380)
    }
    private var scenePreviewSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("受限静态预览").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { showScenePreview = false }.keyboardShortcut(.cancelAction)
            }
            Text(scenePreviewTitle).font(.headline).lineLimit(2)
            Text("离线静态近似画面；视频纹理、脚本及完整效果请通过“播放场景壁纸”查看。")
                .font(.callout).foregroundStyle(.secondary)
            if scenePreviewLoading { ProgressView("正在只读生成静态近似图…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let scenePreviewImage {
                Image(nsImage: scenePreviewImage).resizable().aspectRatio(contentMode: .fit)
                    .accessibilityLabel("受限静态近似图，非桌面动态播放")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("预览不可用", systemImage: "photo.badge.exclamationmark",
                    description: Text(scenePreviewError ?? "此场景没有可显示的受限静态画面。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(20).frame(minWidth: 520, minHeight: 420)
    }
    private func beginScenePreview() {
        guard !scenePreviewLoading, let sceneRoot, let item = selectedPreviewScene else { return }
        scenePreviewTitle = item.title ?? item.name
        scenePreviewImage = nil
        scenePreviewError = nil
        scenePreviewLoading = true
        showScenePreview = true
        Task {
            defer { scenePreviewLoading = false }
            do {
                let raster = try await Task.detached(priority: .userInitiated) {
                    let scoped = sceneRoot.startAccessingSecurityScopedResource()
                    defer { if scoped { sceneRoot.stopAccessingSecurityScopedResource() } }
                    return try SceneStaticPreviewLoader.load(root: sceneRoot, sceneName: item.name,
                                                             expectedBytes: item.packageBytes)
                }.value
                guard showScenePreview, self.sceneRoot == sceneRoot, selectedSceneName == item.name else { return }
                guard let image = SceneStaticPreviewLoader.image(from: raster) else {
                    scenePreviewError = "像素缓冲区无法转换为图片"
                    return
                }
                scenePreviewImage = image
            } catch {
                guard showScenePreview, self.sceneRoot == sceneRoot, selectedSceneName == item.name else { return }
                scenePreviewError = error.localizedDescription
            }
        }
    }
    private func chooseSceneDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "选择包含 Wallpaper Engine 场景子目录的文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            sceneRoot = url
            savedSceneRoot = url.path
            sceneEntries = []
            selectedSceneName = nil
            Task { await loadScenes(from: url) }
        }
    }
    private func loadScenes(from root: URL) async {
        guard !sceneLoading else { return }
        sceneLoading = true; sceneError = nil
        defer { sceneLoading = false }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                let scoped = root.startAccessingSecurityScopedResource()
                defer { if scoped { root.stopAccessingSecurityScopedResource() } }
                return try WESceneInspection.catalog(directory: root, maxPreviewDimension: 480)
            }.value
            guard sceneRoot == root else { return }
            sceneEntries = try JSONDecoder().decode(SceneCatalogPayload.self, from: data).entries
            if !sceneEntries.contains(where: { $0.name == selectedSceneName }) {
                selectedSceneName = sceneEntries.first(where: { $0.name == "1000000001" })?.name ?? sceneEntries.first?.name
            }
        } catch is CancellationError { return }
        catch {
            guard sceneRoot == root else { return }
            sceneEntries = []; sceneError = error.localizedDescription
        }
    }
    private func videoDetails(_ item: Wallpaper) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("视频详情").font(.headline); Spacer()
                    Button { model.selected = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help("关闭详情")
                }
                VideoCover(item: item).aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Label("动态视频壁纸", systemImage: "video").font(.caption).foregroundStyle(.secondary)
                }
                Button { Task { await model.perform(.play(item.id)) } } label: { Label("设为动态壁纸", systemImage: "desktopcomputer").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.return, modifiers: .command).help("设为动态壁纸（⌘Return）").disabled(model.isWorking || !item.playable)
                Text("视频将在桌面背景中持续播放。此处图片仅为视频封面。").font(.caption).foregroundStyle(.secondary)
                if model.stateIssue == nil && model.state.currentPath == item.id { Label("正在桌面播放", systemImage: "waveform").font(.callout).foregroundStyle(.tint) }
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    detailRow("分辨率", "\(item.width) × \(item.height)")
                    detailRow("帧率", String(format: "%.2f FPS", item.fps))
                    detailRow("时长", String(format: "%.1f 秒", item.duration))
                    detailRow("编码", item.codec.uppercased())
                    detailRow("大小", ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
                }.font(.caption)
                if item.decodeWarning { Label("此视频可能使用软件解码", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                if let warning = item.warning { Text(warning).font(.caption).foregroundStyle(.orange) }
                Divider()
                Button("移入废纸篓", systemImage: "trash", role: .destructive) { confirmTrash = true }.disabled(model.isWorking || !model.capabilities.canTrash)
            }.padding(20)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private func detailRow(_ name: String, _ value: String) -> some View { GridRow { Text(name).foregroundStyle(.secondary); Text(value).textSelection(.enabled) } }
    private var rotationSettings: some View {
        Form {
            Section {
                LabeledContent("当前状态", value: model.rotationStatusText)
                if model.state.rotating || model.stateIssue != nil { LabeledContent("当前间隔", value: model.rotationIntervalText) }
            } header: { Text("桌面视频轮播") } footer: { Text("轮播会定时更换桌面正在播放的视频。关闭应用窗口后，已开启的轮播仍会继续。") }
            Section("轮播设置") {
                Picker("切换方式", selection: $mode) {
                    ForEach(model.capabilities.rotationModes, id: \.self) { value in Text(value == "rand" ? "随机" : value == "next" ? "顺序" : "倒序").tag(value) }
                }
                Stepper(value: $minutes, in: 1...1440) { LabeledContent("间隔", value: "\(minutes) 分钟") }
                HStack {
                    Button("应用并开启") { Task { await model.perform(.rotation(minutes * 60, mode)) } }.buttonStyle(.borderedProminent)
                    Button("关闭轮播") { Task { await model.perform(.stopRotation) } }
                }
                if let notice = model.state.notice { Text(notice).foregroundStyle(.orange) }
            }.disabled(model.isWorking)
            Section { Text("“停止桌面播放”保留轮播设置，之后可能再次播放。要恢复静态系统桌面并关闭轮播，请选择“全部关闭”。").font(.callout).foregroundStyle(.secondary) }
        }.formStyle(.grouped)
    }
    private var desktopControls: some View {
        HStack(spacing: 14) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.busy ? "正在切换壁纸…" : scenePlayer.isActive || scenePlayer.phase == .failed ? scenePlayer.statusText : model.stateIssue != nil ? "状态未知" : model.state.running ? "桌面视频播放中" : "桌面壁纸已停止").font(.callout.weight(.medium))
                    if scenePlayer.isActive {
                        Text(scenePlayer.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else if model.stateIssue == nil, let path = model.state.currentPath { Text(URL(fileURLWithPath: path).lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            } icon: { Image(systemName: "desktopcomputer").foregroundStyle(model.state.running || scenePlayer.isActive ? Color.accentColor : Color.secondary) }
            Spacer(minLength: 4)
            if page != .scenes {
                control("backward.end", "上一段视频", .previous)
                control("shuffle", "随机视频", .random)
                control("forward.end", "下一段视频", .next)
            }
            Divider().frame(height: 20)
            Button("停止桌面播放") { Task { await model.perform(.stop) } }.help("停止场景或视频，保留视频轮播设置")
                .disabled(model.busy || scenePlayer.phase == .stopping)
            Button("全部关闭") { Task { await model.perform(.off) } }.help("停止场景和视频，并关闭轮播")
                .disabled(model.busy || scenePlayer.phase == .stopping)
        }.padding(.horizontal, 20).padding(.vertical, 12).background(Color(nsColor: .windowBackgroundColor))
    }
    private func control(_ icon: String, _ title: String, _ action: Action) -> some View { Button { Task { await model.perform(action) } } label: { Image(systemName: icon) }.help(title).accessibilityLabel(title).disabled(model.items.isEmpty || model.isWorking) }
    private func issueBanner(_ text: String) -> some View { Label(text, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
    private func importVideos() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType.mpeg4Movie]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        if panel.runModal() == .OK { Task { await model.importFiles(panel.urls) } }
    }
    private func syncRotationFields() {
        minutes = min(1440, max(1, (model.state.interval ?? 3600) / 60))
        mode = model.capabilities.rotationModes.first(where: { $0 == model.state.mode }) ?? model.capabilities.rotationModes.first ?? "rand"
    }
    private var diagnosticsSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("显示器与运行状态").font(.title2.bold()); Spacer(); Button("完成") { showDiagnostics = false }.keyboardShortcut(.cancelAction) }
            if model.loadingDiagnostics { ProgressView("正在读取…") }
            Text("手动刷新时的诊断快照，不代表实时画面运动。").font(.caption).foregroundStyle(.secondary)
            ScrollView { Text(model.diagnostics.map { $0.displays + "\n" + $0.status } ?? "暂无诊断数据").font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            Text("负载为系统诊断快照，不能单凭 CPU 百分比断定硬件解码或功耗。").font(.caption).foregroundStyle(.secondary)
            Button("刷新诊断") { Task { await model.refreshDiagnostics() } }.disabled(model.loadingDiagnostics)
        }.padding(24).frame(width: 700, height: 480)
    }
}
private struct SceneCover: View {
    let folder: URL?
    @State private var image: NSImage?
    var body: some View {
        GeometryReader { geometry in
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
            } else {
                Rectangle().fill(Color(nsColor: .quaternaryLabelColor))
                    .overlay(Image(systemName: "square.3.layers.3d").font(.largeTitle).foregroundStyle(.secondary))
            }
        }.accessibilityHidden(true).task(id: folder) { image = loadCover() }
    }
    private func loadCover() -> NSImage? {
        guard let folder else { return nil }
        var names = ["preview.jpg", "preview.png", "preview.gif"]
        let project = folder.appendingPathComponent("project.json")
        if let size = try? project.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
           let data = try? Data(contentsOf: project),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = object["preview"] as? String { names.insert(name, at: 0) }
        for name in names where !name.isEmpty && !name.contains("/") && !name.contains("\\") && name != "." && name != ".." {
            let url = folder.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= 16 * 1024 * 1024 else { continue }
            if let image = NSImage(contentsOf: url) { return image }
        }
        return nil
    }
}
private struct VideoCover: View {
    let item: Wallpaper
    var body: some View {
        GeometryReader { geometry in
            if let url = item.thumbnail, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
            } else { Rectangle().fill(Color(nsColor: .quaternaryLabelColor)).overlay(Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)) }
        }.accessibilityHidden(true)
    }
}
private struct VideoCard: View {
    let item: Wallpaper
    let selected: Bool
    let playing: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                VideoCover(item: item).aspectRatio(16 / 9, contentMode: .fit)
                    .overlay(alignment: .bottomTrailing) {
                        Label(String(format: "%.0f 秒", item.duration), systemImage: "video.fill").font(.caption2.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 4)
                            .background(Color(nsColor: .windowBackgroundColor).opacity(0.95), in: Capsule()).padding(6)
                    }.clipShape(RoundedRectangle(cornerRadius: 8))
                Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 4) {
                    if playing { Label("桌面播放中", systemImage: "waveform").foregroundStyle(.tint) }
                    else { Text("\(item.width) × \(item.height)").foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    if item.warning != nil || item.decodeWarning { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                }.font(.caption)
            }.padding(8).background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)).contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).focusable().accessibilityLabel(item.title + "，视频壁纸").accessibilityValue(playing ? "正在桌面播放" : selected ? "已选择" : "未选择")
    }
}
