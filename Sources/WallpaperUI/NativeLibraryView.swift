import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers
import WESceneCore

enum LibraryPage: String, Hashable { case library, videos, scenes, workshop, rotation, settings }
struct NativeLibraryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @EnvironmentObject var model: LibraryModel
    @EnvironmentObject var scenePlayer: ScenePlayer
    @AppStorage("libraryPage") private var page = LibraryPage.library
    @EnvironmentObject private var catalog: UnifiedLibrary
    @EnvironmentObject private var workshop: WorkshopModel
    @State private var search = ""
    @State private var minutes = 60
    @State private var mode = "rand"
    @State private var confirmTrash = false
    @State private var trashPayload: URL?
    @State private var trashTarget: URL?
    @State private var trashStamp: String?
    @State private var showDiagnostics = false
    private var sceneRoot: URL? { selectedScene?.root }
    private var sceneEntries: [SceneCatalogPayload.Entry] { catalog.scenes }
    @State private var selectedSceneName: String?
    private var sceneLoading: Bool { catalog.scanning }
    private var sceneError: String? { catalog.issues.first }
    @State private var visibleSceneLimitations: [String] = []
    @State private var showSceneLimitations = false
    @State private var showScenePreview = false
    @State private var scenePreviewTitle = ""
    @State private var scenePreviewImage: NSImage?
    @State private var scenePreviewError: String?
    @State private var scenePreviewLoading = false
    @State private var coverPreview: SceneCatalogPayload.Entry?
    @State private var videoPreview: Wallpaper?
    @FocusState private var focusedWallpaper: String?
    @State private var keyboardScrollTarget: String?
    @State private var galleryIndex = GalleryIndex<GalleryEntry>()
    @State private var showPlaybackNotes = false
    private var query: String { GalleryNavigation.normalizedQuery(search) }
    private var filtered: [Wallpaper] { model.items.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) } }
    private var selectedVideo: Wallpaper? {
        guard selectedSceneName == nil else { return nil }
        return filtered.first { $0.id == model.selected }
    }
    private var filteredScenes: [SceneCatalogPayload.Entry] {
        sceneEntries.filter { query.isEmpty || ($0.title ?? $0.name).localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
    }
    private var selectedScene: SceneCatalogPayload.Entry? {
        filteredScenes.first { $0.id == selectedSceneName }
    }
    private var selectedSceneLimitations: [String] {
        guard let selectedSceneName else { return [] }
        return filteredScenes.first(where: { $0.id == selectedSceneName })?.capability?.limitationCodes.filter { $0 != "nativeGravityScene" } ?? []
    }
    private var selectedPreviewScene: SceneCatalogPayload.Entry? {
        guard let selectedSceneName,
              let entry = filteredScenes.first(where: { $0.id == selectedSceneName }),
              entry.error == nil, entry.capability?.restrictedStaticPreviewAvailable == true,
              entry.packageBytes > 0, entry.packageBytes <= SceneStaticPreviewLoader.maxPackageBytes else { return nil }
        return entry
    }
    var body: some View {
        NavigationSplitView {
            List(selection: Binding<LibraryPage?>(get: { page }, set: { if let value = $0 { page = value } })) {
                Section("资料库") {
                    SidebarNavigationLabel(title: "全部壁纸", symbol: "photo.on.rectangle", selected: page == .library)
                        .badge(sceneEntries.count + model.items.count).tag(LibraryPage.library)
                    SidebarNavigationLabel(title: "创意工坊", symbol: "square.and.arrow.down", selected: page == .workshop)
                        .tag(LibraryPage.workshop)
                }
                Section("管理") {
                    SidebarNavigationLabel(title: "自动轮播", symbol: "arrow.triangle.2.circlepath", selected: page == .rotation).tag(LibraryPage.rotation)
                    SidebarNavigationLabel(title: "设置", symbol: "gearshape", selected: page == .settings).tag(LibraryPage.settings)
                }
            }.listStyle(.sidebar).navigationTitle(AppStrings.text("壁纸库", locale: locale))
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 230)

        } detail: {
            VStack(spacing: 0) {
                if let issue = model.stateIssue { issueBanner(AppStrings.text("状态暂不可用：", locale: locale) + issue) }
                if let issue = model.libraryIssue { issueBanner(AppStrings.text("素材读取失败：", locale: locale) + issue) }
                if let issue = model.videoBackdropIssue { issueBanner(AppStrings.text(issue, locale: locale)) }
                if let issue = model.backdropCompatibilityIssue { issueBanner(AppStrings.text(issue, locale: locale)) }
                if scenePlayer.isActive, let notice = scenePlayer.notice { issueBanner(AppStrings.text(notice, locale: locale)) }
                if scenePlayer.phase == .failed, let issue = scenePlayer.error, page != .settings {
                    issueBanner(AppStrings.text(issue, locale: locale))
                }
                if page == .settings {
                    WallpaperSettingsView(chooseFolder: chooseSceneDirectory) {
                        showDiagnostics = true; Task { await model.refreshDiagnostics() }
                    }
                }
                else if page == .rotation { rotationSettings }
                else if page == .workshop { WorkshopView { page = .library } }
                else { unifiedLibrary }
                if page != .settings { Divider(); desktopControls }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(AppStrings.text(page == .settings ? "设置" : page == .rotation ? "自动轮播" : page == .workshop ? "创意工坊" : "全部壁纸", locale: locale))
            .modifier(LibrarySearch(text: $search, enabled: page == .library, prompt: "搜索壁纸"))
            .toolbar {
                ToolbarItemGroup {
                    if page == .library {
                        Button(action: chooseSceneDirectory) { Label("添加素材文件夹", systemImage: "folder.badge.plus") }
                        Button { Task { await catalog.refresh() } } label: { Label("检查新素材", systemImage: "arrow.clockwise") }
                            .disabled(catalog.scanning).keyboardShortcut("r", modifiers: .command)
                        Menu {
                            Button(action: importVideos) { Label("导入视频文件", systemImage: "plus") }
                                .disabled(model.isWorking || !model.capabilities.canImport)
                            Divider()
                            Button("静态检查详情", systemImage: "info.circle") {
                                visibleSceneLimitations = selectedSceneLimitations; showSceneLimitations = true
                            }.disabled(selectedSceneLimitations.isEmpty)
                            Button("受限静态预览", systemImage: "photo", action: beginScenePreview)
                                .disabled(selectedPreviewScene == nil || scenePreviewLoading)
                            Button("显示器与运行状态", systemImage: "desktopcomputer") {
                                showDiagnostics = true; Task { await model.refreshDiagnostics() }
                            }
                        } label: { Label("更多", systemImage: "ellipsis.circle") }
                    }
                }
            }
        }
        .task {
            if page == .scenes || page == .videos { page = .library }
            catalog.start()
            syncRotationFields()
        }
        .onReceive(catalog.$scenes.combineLatest(model.$items)) { scenes, videos in
            galleryIndex = GalleryIndex(
                scenes.map { GalleryEntry(id: $0.id, title: $0.title ?? $0.name, scene: $0, video: nil) }
                + videos.map { GalleryEntry(id: $0.id, title: $0.title, scene: nil, video: $0) })
        }
        .onChange(of: catalog.scenes.map(\.id)) { _, ids in
            if let selectedSceneName, !ids.contains(selectedSceneName) { self.selectedSceneName = nil }
        }
        .onChange(of: page) { _, newValue in
            search = ""; coverPreview = nil; videoPreview = nil
            if newValue == .rotation { syncRotationFields() }
        }
        .alert("操作提示", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("知道了") { model.error = nil } } message: { Text(AppStrings.text(model.error ?? "", locale: locale)) }
        .confirmationDialog("将此壁纸移入废纸篓？", isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("移入废纸篓", role: .destructive) {
                guard let payload = trashPayload, let target = trashTarget, let stamp = trashStamp else { return }
                coverPreview = nil; videoPreview = nil
                Task {
                    guard !workshop.busy else { return }
                    if await model.trashWallpaper(payload: payload, confirmedTarget: target, confirmedStamp: stamp, roots: catalog.roots) {
                        workshop.recordRemoval(target)
                        await catalog.didTrash(target)
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { Text(trashTarget?.path ?? "") + Text("\n") + Text("项目文件夹及其素材会一并移入废纸篓，独立视频只移除该文件。受影响的播放与轮播会先停止；可从废纸篓恢复。订阅同步会跳过此项目。") }
        .sheet(isPresented: $showDiagnostics) { diagnosticsSheet }
        .sheet(isPresented: $showSceneLimitations) { sceneLimitationsSheet }
        .sheet(isPresented: $showScenePreview) { scenePreviewSheet }
        .sheet(item: $coverPreview) { SceneCoverPreviewSheet(title: $0.title ?? $0.name, folder: $0.folder) }
        .sheet(item: $videoPreview) { VideoPreviewSheet(item: $0) }
    }
    // Fill each row within a bounded card size; wider windows still add columns.
    private let galleryCardWidth: CGFloat = 192
    private let galleryMaximumCardWidth: CGFloat = 240
    private let galleryGap: CGFloat = 14
    private let galleryInset: CGFloat = 20

    private struct GalleryEntry: Identifiable, GallerySearchable {
        let id: String
        let title: String
        let scene: SceneCatalogPayload.Entry?
        let video: Wallpaper?
        var searchTerms: [String] { [title, scene?.name ?? title] }
    }
    private var galleryEntries: [GalleryEntry] {
        galleryIndex.matching(query)
    }
    private var unifiedLibrary: some View {
        let entries = galleryEntries
        return HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("\(entries.count) " + AppStrings.text("项", locale: locale)).foregroundStyle(.secondary)
                    Spacer()
                    if catalog.scanning { ProgressView().controlSize(.small) }
                }.padding(.horizontal, 24).padding(.vertical, 14)
                if let sceneError { issueBanner(AppStrings.text(sceneError, locale: locale)) }
                if entries.isEmpty && !catalog.scanning {
                    ContentUnavailableView {
                        Label(LocalizedStringKey(query.isEmpty ? "还没有壁纸" : "没有匹配的壁纸"), systemImage: "photo.on.rectangle")
                    } description: {
                        Text(LocalizedStringKey(query.isEmpty ? "添加素材文件夹，自动识别场景和 MP4 视频。" : "试试其他关键词，或清除搜索查看全部壁纸。"))
                    } actions: {
                        if query.isEmpty {
                            Button("添加素材文件夹", action: chooseSceneDirectory)
                        } else {
                            Button("清除搜索") { search = "" }
                        }
                    }
                } else {
                    GeometryReader { geometry in
                        // Reserve space for a non-overlay macOS scroll bar as well.
                        let usableWidth = max(1, geometry.size.width - galleryInset * 2 - 16)
                        let columnCount = max(1, Int((usableWidth + galleryGap) / (galleryCardWidth + galleryGap)))
                        let cardWidth = min(galleryMaximumCardWidth, (usableWidth - CGFloat(columnCount - 1) * galleryGap) / CGFloat(columnCount))
                        let gridWidth = cardWidth * CGFloat(columnCount) + CGFloat(columnCount - 1) * galleryGap
                        let columns = Array(repeating: GridItem(.fixed(cardWidth), spacing: galleryGap, alignment: .top), count: columnCount)
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVGrid(columns: columns, alignment: .leading, spacing: galleryGap) {
                                    ForEach(entries) { entry in
                                        Group {
                                            if let scene = entry.scene { sceneCard(scene) }
                                            else if let video = entry.video {
                                                VideoCard(item: video, selected: selectedSceneName == nil && model.selected == video.id,
                                                    playing: model.stateIssue == nil && model.state.running && model.state.currentPath == video.id) {
                                                    keyboardScrollTarget = nil
                                                    selectedSceneName = nil; model.selected = video.id; focusedWallpaper = video.id
                                                }
                                            }
                                        }.id(entry.id).focused($focusedWallpaper, equals: entry.id)
                                            .onMoveCommand { moveWallpaperSelection($0, columns: columnCount) }
                                            .contextMenu {
                                                Button("在访达中显示", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.id)]) }
                                                Button("移入废纸篓", systemImage: "trash", role: .destructive) { requestTrash(URL(fileURLWithPath: entry.id)) }
                                                    .disabled(model.isWorking || workshop.busy || MaterialRemoval.isBundled(URL(fileURLWithPath: entry.id)))
                                            }
                                    }
                                }
                                .frame(width: gridWidth, alignment: .leading)
                                .frame(maxWidth: .infinity, alignment: .center)
                                // Width tracks the drag directly; only a column change
                                // starts a reflow, instead of restarting every pixel.
                                .animation(LibraryMotion.reflow(reduceMotion), value: columnCount)
                                .animation(nil, value: reduceMotion)
                                    .padding(.horizontal, galleryInset).padding(.bottom, 20).padding(.top, 3)
                            }.onChange(of: keyboardScrollTarget) { _, id in
                                if let id { withAnimation(LibraryMotion.expansion(reduceMotion)) { proxy.scrollTo(id) } }
                            }
                        }
                    }
                }
            }.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            if let scene = selectedScene {
                Divider()
                sceneDetails(scene).id(scene.id).frame(width: 320)
            } else if let video = selectedVideo {
                Divider()
                videoDetails(video).id(video.id).frame(width: 320)
            }
        }
    }
    private func moveWallpaperSelection(_ direction: MoveCommandDirection, columns: Int) {
        let entries = galleryEntries
        guard !entries.isEmpty else { return }
        let index = entries.firstIndex { $0.id == focusedWallpaper }
            ?? entries.firstIndex { $0.id == (selectedSceneName ?? model.selected) }
        let move: GalleryNavigation.Direction
        switch direction { case .left: move = .left; case .right: move = .right; case .up: move = .up; case .down: move = .down; default: return }
        guard let target = GalleryNavigation.targetIndex(from: index, count: entries.count, columns: columns, direction: move) else { return }
        let entry = entries[target]
        selectedSceneName = entry.scene?.id; model.selected = entry.video?.id; focusedWallpaper = entry.id
        keyboardScrollTarget = entry.id
    }

    private func sceneCard(_ item: SceneCatalogPayload.Entry) -> some View {
        let playing = scenePlayer.isActive && scenePlayer.package == URL(fileURLWithPath: item.packagePath)
        let title = item.title ?? item.name
        return GalleryCard(title: title,
                           subtitle: ByteCountFormatter.string(fromByteCount: item.packageBytes, countStyle: .file),
                           badge: "场景", selected: selectedSceneName == item.id,
                           playing: playing, warning: item.error != nil || item.capability?.resourceInspectionAvailable == false,
                           accessibilityKind: "场景壁纸",
                           playbackStatus: playing ? scenePlayer.statusText : nil) {
            keyboardScrollTarget = nil
            selectedSceneName = item.id; model.selected = nil; focusedWallpaper = item.id
        } cover: {
            SceneCover(folder: item.folder)
        }
    }

    private func inspectorHeading(_ title: String, close: @escaping () -> Void) -> some View {
        HStack {
            Text(LocalizedStringKey(title)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .frame(width: 24, height: 24).contentShape(Rectangle()).modifier(HoverHighlight())
                .help("关闭详情").accessibilityLabel("关闭详情")
        }
    }

    private func sceneDetails(_ item: SceneCatalogPayload.Entry) -> some View {
        let sceneRoot: URL? = item.root
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                inspectorHeading("场景详情") { selectedSceneName = nil; focusedWallpaper = nil }
                SceneCover(folder: item.folder, size: .inspector)
                    .modifier(ArtworkCrossfade(identity: (sceneRoot?.path ?? "") + "/" + item.name))
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .bottomLeading) { coverLabel("场景封面").padding(10) }
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title ?? item.name).font(.system(size: 17, weight: .semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity).animation(LibraryMotion.selection(reduceMotion), value: item.name)
                    Label("动态场景", systemImage: "square.3.layers.3d").font(.caption).foregroundStyle(.secondary)
                }
                if let error = item.error {
                    Label(AppStrings.text(error, locale: locale), systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                } else if item.capability?.resourceInspectionAvailable == false {
                    Label("大型场景包已通过文件索引检查；为避免界面卡顿，跳过受限静态分析。仍可尝试动态播放。", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button {
                    guard let sceneRoot else { return }
                    Task { await model.playScene(root: sceneRoot, name: item.name, title: item.title ?? item.name,
                                                  expectedBytes: item.packageBytes) }
                } label: { Label("设为场景壁纸", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 3) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command).help("设为场景壁纸（⌘Return）")
                    .disabled(model.isWorking || !model.sceneRuntimeAvailable || item.error != nil || item.packageBytes <= 0)
                Button { coverPreview = item } label: {
                    Label("封面动画预览", systemImage: "play.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .help("使用封面图做轻微动画，不改变桌面壁纸")
                if item.capability?.limitationCodes.contains("nativeGravityScene") == true {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("自动播放 · 无交互", systemImage: "sparkles").font(.headline)
                        Text("金色吸积盘 · 高等数学公式 · 引力弯曲 · 纵深星空")
                        Text(item.name == "01-Ultra" ? "极致画质 4K：3840 长边 · 高清公式 · 目标 120 FPS" : "性能优先：1600 宽 · 90 步光线积分 · 30 FPS")
                        Text("使用当前画面自动生成 Space 过渡底图。")
                    }.font(.caption).foregroundStyle(.secondary)
                } else if let sceneRoot {
                    let package = sceneRoot.appendingPathComponent(item.name).appendingPathComponent("scene.pkg")
                    SceneInspectorSettings(store: model.scenePreferences,
                                           properties: model.sceneUserProperties, package: package,
                                           catalogRevision: item.propertyCatalogRevision)
                        .id(ScenePreferencesStore.identity(for: package))
                }
                DisclosureGroup("文件信息") {
                    VStack(spacing: 10) {
                        inspectorMetadata("文件大小", ByteCountFormatter.string(fromByteCount: item.packageBytes, countStyle: .file))
                        inspectorMetadata("素材编号", item.name)
                    }.padding(.top, 8)
                }.font(.caption).tint(.secondary)
                DisclosureGroup(isExpanded: Binding(get: { showPlaybackNotes }, set: { value in
                    withAnimation(LibraryMotion.expansion(reduceMotion)) { showPlaybackNotes = value }
                })) {
                    Text("场景跟随当前桌面。开启显示器跟随时，跨屏切换前原屏会继续播放 1.5 秒。\n\n切换桌面的动画中，可能短暂露出系统壁纸。睡眠或退出应用时停止。\n\n设为场景壁纸会关闭视频与自动轮播。关闭窗口后，可从菜单栏停止。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                } label: {
                    Text("预览版播放说明").frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5).modifier(HoverHighlight())
                }.font(.caption).tint(.secondary)
                if let sceneRoot {
                    Button("在访达中显示", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([sceneRoot.appendingPathComponent(item.name)])
                    }.buttonStyle(.link).font(.callout)
                        .padding(.vertical, 5).modifier(HoverHighlight())
                }
                Button("移入废纸篓", systemImage: "trash", role: .destructive) { requestTrash(URL(fileURLWithPath: item.packagePath)) }
                    .buttonStyle(.borderless).font(.callout)
                    .disabled(model.isWorking || workshop.busy || MaterialRemoval.isBundled(item.folder))
            }.padding(20)
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            .task(id: (sceneRoot?.path ?? "") + "/" + item.name) {
                guard let sceneRoot, item.error == nil, item.packageBytes > 0 else { return }
                await model.preloadScene(root: sceneRoot, name: item.name,
                                         title: item.title ?? item.name,
                                         expectedBytes: item.packageBytes)
            }
    }

    private func inspectorMetadata(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey(label)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
        }.font(.caption)
    }

    private func coverLabel(_ label: String) -> some View {
        Text(LocalizedStringKey(label)).font(.system(size: 10, weight: .medium)).foregroundStyle(.white)
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
                    Text(LocalizedStringKey(SceneLimitationLabels.title(for: code)))
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
                    description: Text(LocalizedStringKey(scenePreviewError ?? "此场景没有可显示的受限静态画面。")))
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
                guard showScenePreview, self.sceneRoot == sceneRoot, selectedSceneName == item.id else { return }
                guard let image = SceneStaticPreviewLoader.image(from: raster) else {
                    scenePreviewError = "像素缓冲区无法转换为图片"
                    return
                }
                scenePreviewImage = image
            } catch {
                guard showScenePreview, self.sceneRoot == sceneRoot, selectedSceneName == item.id else { return }
                scenePreviewError = error.localizedDescription
            }
        }
    }
    private func chooseSceneDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.message = "添加素材文件夹，自动识别场景与 MP4 视频，每分钟检查新素材。"
        if panel.runModal() == .OK { for url in panel.urls { catalog.addFolder(url) } }
    }
    private func videoDetails(_ item: Wallpaper) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                inspectorHeading("视频详情") { model.selected = nil; focusedWallpaper = nil }
                VideoCover(item: item, size: .inspector).modifier(ArtworkCrossfade(identity: item.id)).aspectRatio(4 / 3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .bottomLeading) { coverLabel("视频封面").padding(10) }
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title).font(.system(size: 17, weight: .semibold)).textSelection(.enabled)
                        .contentTransition(.opacity).animation(LibraryMotion.selection(reduceMotion), value: item.id)
                    Label("动态视频", systemImage: "play.rectangle").font(.caption).foregroundStyle(.secondary)
                }
                Button { Task { await model.perform(.play(item.id)) } } label: {
                    Label("设为动态壁纸", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 3)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command).help("设为动态壁纸（⌘Return）").disabled(model.isWorking || !item.playable)
                Button { videoPreview = item } label: {
                    Label("动态预览", systemImage: "play.rectangle").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).disabled(!item.playable)
                if model.stateIssue == nil && model.state.running && model.state.currentPath == item.id {
                    Label("正在桌面播放", systemImage: "waveform").font(.caption).foregroundStyle(.tint)
                }
                VideoInspectorSettings(store: model.videoBackdropPreferences,
                                       backdrop: model.videoBackdrop, video: item)
                    .id(item.id)
                DisclosureGroup("视频信息") {
                    VStack(alignment: .leading, spacing: 10) {
                        inspectorMetadata("分辨率", "\(item.width) × \(item.height)")
                        inspectorMetadata("帧率", String(format: "%.2f FPS", item.fps))
                        inspectorMetadata("时长", String(format: AppStrings.text("%.1f 秒", locale: locale), item.duration))
                        inspectorMetadata("编码", item.codec.uppercased())
                        inspectorMetadata("文件大小", ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
                    }.padding(.top, 8)
                }.font(.caption).tint(.secondary)
                if item.decodeWarning { Label("此视频可能使用软件解码", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                if let warning = item.warning { Text(warning).font(.caption).foregroundStyle(.orange) }
                Divider()
                Button("在访达中显示", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }.buttonStyle(.link).font(.callout)
                Button("移入废纸篓", systemImage: "trash", role: .destructive) { requestTrash(item.url) }
                    .buttonStyle(.borderless).font(.callout).disabled(model.isWorking || workshop.busy || !model.capabilities.canTrash)
            }.padding(20)
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }
    private func requestTrash(_ payload: URL) {
        guard !model.isWorking, !workshop.busy else { return }
        do {
            trashTarget = try MaterialRemoval.target(for: payload, roots: catalog.roots)
            trashStamp = try MaterialDiscovery.stamp(payload)
            trashPayload = payload; confirmTrash = true
        } catch { model.error = error.localizedDescription }
    }
    private var rotationSettings: some View {
        Form {
            Section {
                LabeledContent("当前状态", value: AppStrings.text(model.rotationStatusText, locale: locale))
                if model.state.rotating || model.stateIssue != nil { LabeledContent("当前间隔", value: AppStrings.text(model.rotationIntervalText, locale: locale)) }
            } header: { Text("状态") }
            Section {
                if let directory = model.capabilities.libraryDirectory {
                    Text(directory.path).font(.caption).textSelection(.enabled)
                }
            } header: { Text("轮播范围") } footer: { Text("仅轮播此文件夹中的视频。") }
            Section("切换设置") {
                Picker("切换方式", selection: $mode) {
                    ForEach(model.capabilities.rotationModes, id: \.self) { value in Text(LocalizedStringKey(value == "rand" ? "随机" : value == "next" ? "顺序" : "倒序")).tag(value) }
                }
                Stepper(value: $minutes, in: 1...1440) { LabeledContent("间隔", value: "\(minutes) " + AppStrings.text("分钟", locale: locale)) }
                HStack {
                    Button("应用并开启") { Task { await model.perform(.rotation(minutes * 60, mode)) } }.buttonStyle(.borderedProminent)
                    Button("关闭轮播") { Task { await model.perform(.stopRotation) } }
                }
                if let notice = model.state.notice { Text(LocalizedStringKey(notice)).foregroundStyle(.orange) }
            }.disabled(model.isWorking)
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
                Text(LocalizedStringKey(scenePlayer.applyingEffects ? "正在应用场景效果…" : model.busy ? "正在切换壁纸…" : scenePlayer.isActive || scenePlayer.phase == .failed ? scenePlayer.statusText : model.stateIssue != nil ? "状态未知" : model.state.running ? "桌面视频播放中" : "桌面待机"))
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(LocalizedStringKey(playbackSubtitle)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if selectedSceneName == nil {
                HStack(spacing: 3) {
                    control("backward.end.fill", "上一段视频", .previous)
                    control("shuffle", "随机视频", .random)
                    control("forward.end.fill", "下一段视频", .next)
                }
                Divider().frame(height: 22)
            }
            if scenePlayer.supportsControls {
                Button { scenePlayer.togglePause() } label: {
                    Label(LocalizedStringKey(scenePlayer.manualPause ? "继续场景" : "暂停场景"), systemImage: scenePlayer.manualPause ? "play.fill" : "pause.fill")
                }.disabled(model.isWorking)
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
        if model.state.running, let path = model.state.currentPath {
            return model.items.first(where: { $0.id == path })?.title ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
        if model.state.rotating { return "自动轮播已开启 · 等待下一次切换" }
        return "未播放壁纸"
    }
    private func control(_ icon: String, _ title: String, _ action: Action) -> some View {
        Button { Task { await model.perform(action) } } label: {
            Image(systemName: icon).font(.system(size: 12)).frame(width: 27, height: 27).contentShape(Rectangle())
        }.buttonStyle(.borderless).help(AppStrings.text(title, locale: locale))
            .accessibilityLabel(AppStrings.text(title, locale: locale)).disabled(model.items.isEmpty || model.isWorking)
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
            ScrollView { Text(model.diagnostics.map { $0.displays + "\n" + $0.status } ?? AppStrings.text("暂无诊断数据", locale: locale)).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            Text("负载为系统诊断快照，不能单凭 CPU 百分比断定硬件解码或功耗。").font(.caption).foregroundStyle(.secondary)
            Button("刷新诊断") { Task { await model.refreshDiagnostics() } }.disabled(model.loadingDiagnostics)
        }.padding(24).frame(width: 700, height: 480)
    }
}
private struct SceneCover: View {
    let folder: URL?
    var size: CoverSize = .card
    var body: some View { LibraryCover(source: .scene(folder), symbol: "square.3.layers.3d", size: size) }
}
private struct SceneCoverPreviewSheet: View {
    let title: String
    let folder: URL?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drifting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("封面动画预览").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(title).font(.headline).lineLimit(2)
            GeometryReader { geometry in
                SceneCover(folder: folder, size: .inspector)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .scaleEffect(reduceMotion ? 1 : (drifting ? 1.13 : 1.05))
                    .offset(x: reduceMotion ? 0 : (drifting ? -12 : 12),
                            y: reduceMotion ? 0 : (drifting ? 8 : -8))
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel("封面动画预览")
            Text("封面动画仅用于预览；实际场景效果以桌面播放为准。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 490)
        .onAppear { drifting = true }
        .onDisappear { drifting = false }
        .animation(reduceMotion ? nil : .easeInOut(duration: 7).repeatForever(autoreverses: true), value: drifting)
    }
}
private struct VideoCover: View {
    let item: Wallpaper
    var size: CoverSize = .card
    var body: some View { LibraryCover(source: .video(item.thumbnail), symbol: "film", size: size) }
}
private struct VideoCard: View {
    @Environment(\.locale) private var locale
    let item: Wallpaper
    let selected: Bool
    let playing: Bool
    let action: () -> Void
    var body: some View {
        GalleryCard(title: item.title, subtitle: "\(item.width) × \(item.height)",
                    badge: String(format: AppStrings.text("%.0f 秒", locale: locale), item.duration), selected: selected,
                    playing: playing, warning: item.warning != nil || item.decodeWarning,
                    accessibilityKind: "视频壁纸", playbackStatus: playing ? "正在桌面播放" : nil,
                    action: action) {
            VideoCover(item: item)
        }
    }
}

private struct GalleryCard<Cover: View>: View {
    @Environment(\.locale) private var locale
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
        let selection = AppStrings.text(selected ? "已选择" : "未选择", locale: locale)
        guard playing else { return selection }
        return selection + ", " + AppStrings.text(playbackStatus ?? "正在桌面播放", locale: locale)
    }
    var body: some View {
        Button(action: action) { cardSurface }
            .buttonStyle(GalleryPressStyle())
            .focusable()
            .onHover { hovered = $0 }
            .onDisappear { hovered = false }
            .animation(LibraryMotion.feedback(reduceMotion), value: hovered)
            .animation(LibraryMotion.selection(reduceMotion), value: selected)
            .animation(nil, value: reduceMotion)
            .accessibilityLabel(Text(title + ", " + AppStrings.text(accessibilityKind, locale: locale)))
            .accessibilityValue(Text(accessibilityStatus))
            .help(title)
    }
    private var cardSurface: some View {
        VStack(alignment: .leading, spacing: 0) {
            artwork
            caption
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(borderColor, lineWidth: selected ? 1.5 : 0.5))
        .shadow(color: Color.accentColor.opacity(selected ? 0.13 : 0), radius: selected ? 5 : 0)
        .shadow(color: Color.black.opacity(hovered ? 0.09 : 0.015), radius: hovered ? CGFloat(9) : CGFloat(2), x: 0, y: hovered ? 3 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
    private var artwork: some View {
        HoverArtwork(active: hovered) { cover() }.aspectRatio(16 / 9, contentMode: .fit)
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.38)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                Label(LocalizedStringKey(badgeText), systemImage: badgeIcon)
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
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.78)))
                }
            }
    }
    private var caption: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                Text(subtitle).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if warning { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
            }.font(.system(size: 11))
        }.padding(10)
    }
}

private struct LibrarySearch: ViewModifier {
    @Binding var text: String
    let enabled: Bool
    let prompt: String
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.searchable(text: $text, placement: .toolbar, prompt: Text(LocalizedStringKey(prompt))) }
        else { content }
    }
}
