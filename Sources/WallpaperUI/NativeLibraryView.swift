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
    @FocusState private var focusedScene: String?
    @State private var showPlaybackNotes = false
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
                    Label("场景壁纸", systemImage: "square.3.layers.3d").badge(sceneEntries.count).tag(LibraryPage.scenes)
                    Label("视频壁纸", systemImage: "play.rectangle").badge(model.items.count).tag(LibraryPage.videos)
                }
                Section("桌面") { Label("自动轮播", systemImage: "arrow.triangle.2.circlepath").tag(LibraryPage.rotation) }
            }.listStyle(.sidebar).navigationTitle("壁纸库")
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 230)
                .safeAreaInset(edge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "rectangle.inset.filled").font(.system(size: 22, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("让桌面，生动起来。")
                            .font(.system(size: 13, weight: .medium))
                        Text("你的私人动态壁纸库")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
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
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(page == .rotation ? "自动轮播" : page == .scenes ? "场景壁纸" : "视频壁纸")
            .navigationSubtitle(page == .rotation ? "让风景按时焕新" : "本地资料库")
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
    private let galleryColumns = [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)]

    private func galleryHeading(_ title: String, subtitle: String, count: Int, preview: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 25, weight: .semibold)).tracking(-0.6)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if preview {
                Text("预览版").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.quaternary.opacity(0.45), in: Capsule())
            }
            Text("\(count) 款").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }.padding(.horizontal, 24).padding(.top, 25).padding(.bottom, 22)
    }

    private var videoLibrary: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                galleryHeading("流动的风景", subtitle: "收藏片刻，循环成日常。", count: filtered.count)
                if model.loading { ProgressView("正在读取视频…").padding() }
                if !model.loading && filtered.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "添加你的第一段视频" : "没有匹配的视频", systemImage: "film.stack", description: Text(search.isEmpty ? "导入 MP4，让视频在桌面背景持续播放。" : "试试其他关键词。"))
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: galleryColumns, spacing: 20) {
                                ForEach(filtered) { item in
                                    VideoCard(item: item, selected: model.selected == item.id,
                                              playing: model.stateIssue == nil && model.state.running && model.state.currentPath == item.id) {
                                        model.selected = item.id; focusedVideo = item.id
                                    }
                                    .id(item.id)
                                    .focused($focusedVideo, equals: item.id)
                                    .onMoveCommand { direction in
                                        moveVideoSelection(direction)
                                    }
                                }
                            }.padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 3)
                        }
                        .onChange(of: focusedVideo) { _, id in if let id { proxy.scrollTo(id) } }
                    }
                }
            }.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Group {
                if let item = model.selectedWallpaper { videoDetails(item) }
                else { inspectorPlaceholder("选择一段风景", subtitle: "点选视频，查看详情并设为桌面壁纸。", icon: "play.rectangle") }
            }.frame(width: 280)
        }
    }

    private var sceneLibrary: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                galleryHeading("桌面，自成风景", subtitle: "光影与细节，在桌面缓缓展开。", count: filteredScenes.count, preview: true)
                if !model.sceneRuntimeAvailable { issueBanner("场景运行组件缺失，请使用包含 Scene 的完整构建。") }
                if let error = scenePlayer.error { issueBanner(error) }
                if let sceneError { issueBanner("场景读取失败：" + sceneError) }
                if sceneLoading { ProgressView("正在读取场景…").padding() }
                if sceneRoot == nil {
                    ContentUnavailableView {
                        Label("添加场景壁纸", systemImage: "square.3.layers.3d")
                    } description: {
                        Text("选择包含场景的素材文件夹，开始布置你的桌面。")
                    } actions: {
                        Button("选择文件夹", action: chooseSceneDirectory).buttonStyle(.borderedProminent)
                    }.frame(maxHeight: .infinity)
                } else if !sceneLoading && sceneEntries.isEmpty && sceneError == nil {
                    ContentUnavailableView("尚未找到场景", systemImage: "square.3.layers.3d",
                        description: Text("请选择包含 scene.pkg 子目录的素材文件夹。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !sceneLoading && filteredScenes.isEmpty && sceneError == nil {
                    ContentUnavailableView("没有匹配的场景", systemImage: "magnifyingglass",
                        description: Text("试试其他标题或目录编号。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: galleryColumns, spacing: 20) {
                                ForEach(filteredScenes) { item in
                                    sceneCard(item).id(item.name)
                                        .focused($focusedScene, equals: item.name)
                                        .onMoveCommand { direction in moveSceneSelection(direction) }
                                }
                            }.padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 3)
                        }
                        .onChange(of: focusedScene) { _, id in if let id { proxy.scrollTo(id) } }
                    }
                }
            }.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Group {
                if let item = selectedScene { sceneDetails(item) }
                else { inspectorPlaceholder("选择一幅风景", subtitle: "点选场景，查看详情并设为桌面壁纸。", icon: "square.3.layers.3d") }
            }.frame(width: 280)
        }
    }

    private func sceneCard(_ item: SceneCatalogPayload.Entry) -> some View {
        let playing = scenePlayer.isActive && scenePlayer.package == sceneRoot?.appendingPathComponent(item.name).appendingPathComponent("scene.pkg")
        let title = item.title ?? item.name
        return GalleryCard(title: title,
                           subtitle: ByteCountFormatter.string(fromByteCount: item.packageBytes, countStyle: .file),
                           badge: "场景", selected: selectedSceneName == item.name,
                           playing: playing, warning: item.error != nil,
                           accessibilityKind: "场景壁纸",
                           playbackStatus: playing ? scenePlayer.statusText : nil) {
            selectedSceneName = item.name; focusedScene = item.name
        } cover: {
            SceneCover(folder: sceneRoot?.appendingPathComponent(item.name))
        }
    }

    private func moveSceneSelection(_ direction: MoveCommandDirection) {
        let ids = filteredScenes.map(\.name)
        guard !ids.isEmpty else { return }
        let index = ids.firstIndex(of: selectedSceneName ?? "") ?? 0
        let step: Int
        switch direction { case .left: step = -1; case .right: step = 1; case .up: step = -2; case .down: step = 2; default: return }
        selectedSceneName = ids[min(max(index + step, 0), ids.count - 1)]
        focusedScene = selectedSceneName
    }

    private func moveVideoSelection(_ direction: MoveCommandDirection) {
        let ids = filtered.map(\.id)
        guard !ids.isEmpty else { return }
        let index = ids.firstIndex(of: model.selected ?? "") ?? 0
        let step: Int
        switch direction { case .left: step = -1; case .right: step = 1; case .up: step = -2; case .down: step = 2; default: return }
        model.selected = ids[min(max(index + step, 0), ids.count - 1)]
        focusedVideo = model.selected
    }

    private func inspectorPlaceholder(_ title: String, subtitle: String, icon: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 32, weight: .ultraLight)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private func inspectorHeading(_ title: String, close: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .frame(width: 24, height: 24).contentShape(Rectangle())
                .help("关闭详情").accessibilityLabel("关闭详情")
        }
    }

    private func sceneDetails(_ item: SceneCatalogPayload.Entry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                inspectorHeading("场景详情") { selectedSceneName = nil; focusedScene = nil }
                SceneCover(folder: sceneRoot?.appendingPathComponent(item.name))
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .bottomLeading) { coverLabel("场景封面").padding(10) }
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title ?? item.name).font(.system(size: 19, weight: .semibold)).tracking(-0.35).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Label("动态场景", systemImage: "square.3.layers.3d").font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    guard let sceneRoot else { return }
                    Task { await model.playScene(root: sceneRoot, name: item.name, title: item.title ?? item.name,
                                                  expectedBytes: item.packageBytes, fps: sceneFPS, cropMode: sceneCropMode) }
                } label: { Label("设为场景壁纸", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 3) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command).help("设为场景壁纸（⌘Return）")
                    .disabled(model.isWorking || !model.sceneRuntimeAvailable || item.error != nil || item.packageBytes <= 0 || item.packageBytes > 256 * 1024 * 1024)
                VStack(alignment: .leading, spacing: 14) {
                    Text("播放设置").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("帧率上限").font(.callout)
                        Picker("帧率上限", selection: $sceneFPS) {
                            Text("30 FPS").tag(30)
                            Text("60 FPS").tag(60)
                        }.pickerStyle(.segmented).labelsHidden()
                    }
                    Picker("画面位置", selection: $sceneCropMode) {
                        Text("自动适配").tag("auto")
                        Text("居中").tag("center")
                        Text("靠左").tag("left")
                        Text("靠右").tag("right")
                    }.font(.callout)
                    Text("修改后，重新设为壁纸即可生效。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                VStack(spacing: 10) {
                    inspectorMetadata("文件大小", ByteCountFormatter.string(fromByteCount: item.packageBytes, countStyle: .file))
                    inspectorMetadata("素材编号", item.name)
                }
                DisclosureGroup("预览版播放说明", isExpanded: $showPlaybackNotes) {
                    Text("场景跟随当前桌面与显示器。跨屏切换时，原屏会继续播放 1.5 秒。\n\n切换桌面的动画中，可能短暂露出系统壁纸。场景静音，睡眠或退出应用时停止。\n\n设为场景壁纸会关闭视频与自动轮播。关闭窗口后，可从菜单栏停止。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                }.font(.caption).tint(.secondary)
                if let sceneRoot {
                    Button("在访达中显示", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([sceneRoot.appendingPathComponent(item.name)])
                    }.buttonStyle(.link).font(.callout)
                }
            }.padding(20)
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private func inspectorMetadata(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
        }.font(.caption)
    }

    private func coverLabel(_ label: String) -> some View {
        Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4).background(.black.opacity(0.45), in: Capsule())
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
            Text("离线静态近似画面；视频纹理、脚本及完整效果请通过“设为场景壁纸”查看。")
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
            VStack(alignment: .leading, spacing: 20) {
                inspectorHeading("视频详情") { model.selected = nil; focusedVideo = nil }
                VideoCover(item: item).aspectRatio(4 / 3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .bottomLeading) { coverLabel("视频封面").padding(10) }
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title).font(.system(size: 19, weight: .semibold)).tracking(-0.35).textSelection(.enabled)
                    Label("动态视频", systemImage: "play.rectangle").font(.caption).foregroundStyle(.secondary)
                }
                Button { Task { await model.perform(.play(item.id)) } } label: {
                    Label("设为动态壁纸", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 3)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command).help("设为动态壁纸（⌘Return）").disabled(model.isWorking || !item.playable)
                if model.stateIssue == nil && model.state.running && model.state.currentPath == item.id {
                    Label("正在桌面播放", systemImage: "waveform").font(.caption).foregroundStyle(.tint)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("视频信息").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    inspectorMetadata("分辨率", "\(item.width) × \(item.height)")
                    inspectorMetadata("帧率", String(format: "%.2f FPS", item.fps))
                    inspectorMetadata("时长", String(format: "%.1f 秒", item.duration))
                    inspectorMetadata("编码", item.codec.uppercased())
                    inspectorMetadata("文件大小", ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
                }.padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                Text("视频在桌面背景持续播放。上方图片仅为封面。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if item.decodeWarning { Label("此视频可能使用软件解码", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                if let warning = item.warning { Text(warning).font(.caption).foregroundStyle(.orange) }
                Divider()
                Button("移入废纸篓", systemImage: "trash", role: .destructive) { confirmTrash = true }
                    .buttonStyle(.borderless).font(.callout).disabled(model.isWorking || !model.capabilities.canTrash)
            }.padding(20)
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }
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
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "desktopcomputer").font(.system(size: 22, weight: .light)).foregroundStyle(.secondary)
                Circle().fill(model.stateIssue != nil && !scenePlayer.isActive ? Color.orange : scenePlayer.isActive || model.state.running ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7).overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2)).offset(x: 3, y: 0)
            }.frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.busy ? "正在切换壁纸…" : scenePlayer.isActive || scenePlayer.phase == .failed ? scenePlayer.statusText : model.stateIssue != nil ? "状态未知" : model.state.running ? "桌面视频播放中" : "桌面待机")
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(playbackSubtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if page != .scenes {
                HStack(spacing: 3) {
                    control("backward.end.fill", "上一段视频", .previous)
                    control("shuffle", "随机视频", .random)
                    control("forward.end.fill", "下一段视频", .next)
                }
                Divider().frame(height: 22)
            }
            Button { Task { await model.perform(.stop) } } label: {
                Label("停止", systemImage: "stop.fill").font(.system(size: 11, weight: .medium))
            }.help("停止场景或视频，保留视频轮播设置").accessibilityLabel("停止桌面播放")
                .disabled(model.busy || scenePlayer.phase == .stopping)
            Button("全部关闭") { Task { await model.perform(.off) } }
                .font(.system(size: 11, weight: .medium)).help("停止场景和视频，并关闭轮播")
                .disabled(model.busy || scenePlayer.phase == .stopping)
        }.controlSize(.regular).padding(.horizontal, 24).padding(.vertical, 14)
            .background(Color(nsColor: .windowBackgroundColor))
    }
    private var playbackSubtitle: String {
        if scenePlayer.isActive { return scenePlayer.title }
        if model.stateIssue != nil { return "暂时无法读取桌面播放状态" }
        if model.state.running, let path = model.state.currentPath { return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
        if model.state.rotating { return "自动轮播已开启 · 等待下一次切换" }
        return "选一幅喜欢的风景，留在桌面。"
    }
    private func control(_ icon: String, _ title: String, _ action: Action) -> some View {
        Button { Task { await model.perform(action) } } label: {
            Image(systemName: icon).font(.system(size: 12)).frame(width: 27, height: 27).contentShape(Rectangle())
        }.buttonStyle(.borderless).help(title).accessibilityLabel(title).disabled(model.items.isEmpty || model.isWorking)
    }
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
        GalleryCard(title: item.title, subtitle: "\(item.width) × \(item.height)",
                    badge: String(format: "%.0f 秒", item.duration), selected: selected,
                    playing: playing, warning: item.warning != nil || item.decodeWarning,
                    accessibilityKind: "视频壁纸", playbackStatus: playing ? "正在桌面播放" : nil,
                    action: action) {
            VideoCover(item: item)
        }
    }
}

private struct GalleryCard<Cover: View>: View {
    let title: String
    let subtitle: String
    let badge: String
    let selected: Bool
    let playing: Bool
    let warning: Bool
    let accessibilityKind: String
    let playbackStatus: String?
    let action: () -> Void
    @ViewBuilder let cover: () -> Cover
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var borderColor: Color { selected ? .accentColor : .primary.opacity(hovered ? 0.18 : 0.07) }
    private var badgeIcon: String { playing ? "waveform" : accessibilityKind == "视频壁纸" ? "play.fill" : "square.3.layers.3d" }
    private var badgeText: String { playing ? (playbackStatus ?? "桌面播放中") : badge }

    private var accessibilityStatus: String {
        let selection = selected ? "已选择" : "未选择"
        guard playing else { return selection }
        return selection + "，" + (playbackStatus ?? "正在桌面播放")
    }
    var body: some View {
        Button(action: action) { cardSurface }
            .buttonStyle(.plain)
            .focusable()
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : Animation.easeOut(duration: 0.16), value: hovered)
            .accessibilityLabel(Text(title + "，" + accessibilityKind))
            .accessibilityValue(Text(accessibilityStatus))
            .help(title)
    }
    private var cardSurface: some View {
        VStack(alignment: .leading, spacing: 0) {
            artwork
            caption
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(borderColor, lineWidth: selected ? 2.0 : 1.0))
        .shadow(color: Color.black.opacity(hovered ? 0.10 : 0.035), radius: hovered ? CGFloat(9) : CGFloat(4), x: 0, y: hovered ? CGFloat(4) : CGFloat(2))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
    private var artwork: some View {
        cover().aspectRatio(16 / 10, contentMode: .fit)
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.38)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                Label(badgeText, systemImage: badgeIcon)
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.black.opacity(0.38), in: Capsule()).padding(10)
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white).frame(width: 23, height: 23)
                        .background(Color.accentColor, in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1.5)).padding(10)
                }
            }
    }
    private var caption: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                Text(subtitle).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if warning { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
            }.font(.system(size: 11))
        }.padding(13)
    }
}
