import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers
import WESceneCore

enum LibraryPage: String, Hashable { case library, videos, scenes, workshop, rotation, settings }
enum LibraryKindFilter: String, CaseIterable, Identifiable {
    case all, scenes, videos
    var id: String { rawValue }
    var label: String { switch self { case .all: return "全部"; case .scenes: return "场景"; case .videos: return "视频" } }
}
struct NativeLibraryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @EnvironmentObject var playback: DisplayPlayback
    @EnvironmentObject var model: LibraryModel
    @EnvironmentObject var scenePlayer: ScenePlayer
    @AppStorage("libraryPage") private var page = LibraryPage.library
    @EnvironmentObject private var catalog: UnifiedLibrary
    @EnvironmentObject private var workshop: WorkshopModel
    @EnvironmentObject private var collection: LibraryCollectionStore
    @State private var search = ""
    @State private var showHidden = false
    @State private var isSelecting = false
    @State private var batchSelection = GalleryBatchSelection()
    @State private var visibilityUndo: (ids: Set<String>, hidden: Bool)?
    @State private var batchMessage: String?
    @State private var batchTrashPreview: BatchTrashPreview?
    @State private var rotationUsesSelection = false
    @State private var selectionRotationDraft = RotationDraft()
    @State private var rotationDraft = RotationDraft()
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
    @FocusState private var focusedWallpaper: String?
    @State private var keyboardScrollTarget: String?
    @State private var galleryIndex = GalleryIndex<GalleryEntry>()
    @State private var showPlaybackNotes = false
    @AppStorage("libraryKindFilter") private var kindFilter = LibraryKindFilter.all
    @AppStorage("galleryCardScale") private var cardScale = 1.0
    /// Wallpaper the hero shows when nothing is selected ("换一张").
    @State private var spotlightID: String?
    @State private var toast: (id: UUID, text: String)?
    private var query: String { GalleryNavigation.normalizedQuery(search) }
    private var filtered: [Wallpaper] { model.items.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) } }
    private var selectedVideo: Wallpaper? {
        guard !isSelecting, selectedSceneName == nil else { return nil }
        guard galleryEntries.contains(where: { $0.id == model.selected }) else { return nil }
        return filtered.first { $0.id == model.selected }
    }
    private var filteredScenes: [SceneCatalogPayload.Entry] {
        sceneEntries.filter { query.isEmpty || ($0.title ?? $0.name).localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
    }
    private var selectedScene: SceneCatalogPayload.Entry? {
        guard !isSelecting, galleryEntries.contains(where: { $0.id == selectedSceneName }) else { return nil }
        return filteredScenes.first { $0.id == selectedSceneName }
    }
    private var selectedSceneLimitations: [String] {
        guard let selectedSceneName else { return [] }
        return filteredScenes.first(where: { $0.id == selectedSceneName })?.capability?.limitationCodes.filter { $0 != "nativeGravityScene" && $0 != "nativeMoonScene" } ?? []
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
                        .badge(galleryIndex.matching("").filter { !collection.hiddenIDs.contains($0.visibilityID) }.count).tag(LibraryPage.library)
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
                if let issue = playback.issue { issueBanner(AppStrings.text(issue, locale: locale)) }
                if let issue = model.stateIssue { issueBanner(AppStrings.text("状态暂不可用：", locale: locale) + issue) }
                if let issue = model.libraryIssue { issueBanner(AppStrings.text("素材读取失败：", locale: locale) + issue) }
                if page != .settings, let issue = model.videoBackdropIssue { issueBanner(AppStrings.text(issue, locale: locale)) }
                if let issue = model.backdropCompatibilityIssue { issueBanner(AppStrings.text(issue, locale: locale)) }
                if scenePlayer.isActive, let notice = scenePlayer.notice { issueBanner(AppStrings.text(notice, locale: locale)) }
                if scenePlayer.phase == .failed, let issue = scenePlayer.error, page != .settings {
                    issueBanner(AppStrings.text(issue, locale: locale))
                }
                Group {
                    if page == .settings {
                        WallpaperSettingsView(chooseFolder: chooseSceneDirectory) {
                            showDiagnostics = true; Task { await model.refreshDiagnostics() }
                        }
                    }
                    else if page == .rotation { rotationSettings }
                    else if page == .workshop { WorkshopView { page = .library } }
                    else { unifiedLibrary }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Content scrolls beneath the floating dock instead of stopping above a bar.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if page != .settings { nowPlayingDock.padding(.horizontal, 16).padding(.bottom, 14).padding(.top, 6) }
                }
            }
            .background {
                if page == .library {
                    AmbientBackdrop(source: heroEntry.map(coverSource), identity: heroEntry?.id ?? "")
                } else {
                    Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
                }
            }
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
            rotationUsesSelection = model.targetDisplayUUID != nil || !collection.rotationItems.isEmpty
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
            if newValue != .library { isSelecting = false; batchSelection.clear() }
            if newValue == .rotation && !rotationDraft.isEdited { syncRotationFields() }
        }
        .onChange(of: galleryEntries.map(\.id)) { _, ids in batchSelection.retain(ids) }
        .onChange(of: showHidden) { _, _ in
            batchSelection.clear(); selectedSceneName = nil; model.selected = nil; focusedWallpaper = nil
        }
        .onChange(of: model.state) { _, state in
            if !rotationDraft.isEdited || rotationDraft.matches(interval: state.interval, mode: state.mode) {
                syncRotationFields()
            }
        }
        .alert("操作提示", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("知道了") { model.error = nil } } message: { Text(AppStrings.text(model.error ?? "", locale: locale)) }
        .confirmationDialog("将此壁纸移入废纸篓？", isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("移入废纸篓", role: .destructive) {
                guard let payload = trashPayload, let target = trashTarget, let stamp = trashStamp else { return }
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
        .sheet(item: $batchTrashPreview) { preview in
            BatchTrashSheet(requests: preview.requests, skipped: preview.skipped,
                            cancel: { batchTrashPreview = nil },
                            confirm: { executeBatchTrash(preview.requests) })
        }
    }
    // Fill each row within a bounded card size; wider windows still add columns.
    private let galleryCardWidth: CGFloat = 208
    private let galleryMaximumCardWidth: CGFloat = 280
    private let galleryGap: CGFloat = 18
    private let galleryInset: CGFloat = 24

    private struct GalleryEntry: Identifiable, GallerySearchable {
        let id: String
        let title: String
        let scene: SceneCatalogPayload.Entry?
        let video: Wallpaper?
        let visibilityID: String
        init(id: String, title: String, scene: SceneCatalogPayload.Entry?, video: Wallpaper?) {
            self.id = id; self.title = title; self.scene = scene; self.video = video
            visibilityID = LibraryCollectionStore.identity(URL(fileURLWithPath: id))
        }
        var searchTerms: [String] { [title, scene?.name ?? title] }
        var rotationWallpaper: RotationWallpaper? {
            if let scene, scene.error == nil, scene.packageBytes > 0 {
                return .init(url: URL(fileURLWithPath: id), title: title, kind: .scene, expectedBytes: scene.packageBytes)
            }
            if let video, video.playable { return .init(url: video.url, title: title, kind: .video) }
            return nil
        }
    }
    private var galleryEntries: [GalleryEntry] {
        galleryIndex.matching(query).filter {
            collection.hiddenIDs.contains($0.visibilityID) == showHidden
                && (kindFilter == .all || (kindFilter == .scenes) == ($0.scene != nil))
        }
    }
    private var batchEntries: [GalleryEntry] { galleryEntries.filter { batchSelection.ids.contains($0.id) } }
    private var showsHero: Bool { query.isEmpty && !isSelecting }
    /// Spotlight priority: explicit selection, then what plays on the chosen display, then the first wallpaper.
    private var heroEntry: GalleryEntry? {
        let entries = galleryEntries
        if let id = selectedSceneName ?? model.selected, let entry = entries.first(where: { $0.id == id }) { return entry }
        if let spotlightID, let entry = entries.first(where: { $0.id == spotlightID }) { return entry }
        return entries.first(where: isPlaying) ?? entries.first
    }
    private func isPlaying(_ entry: GalleryEntry) -> Bool {
        if let scene = entry.scene { return scenePlayer.isActive && scenePlayer.package == URL(fileURLWithPath: scene.packagePath) }
        return model.stateIssue == nil && model.state.running && model.state.currentPath == entry.id
    }
    private func coverSource(_ entry: GalleryEntry) -> CoverSource {
        if let video = entry.video { return .videoProject(folder: video.url.deletingLastPathComponent(), fallback: video.thumbnail) }
        return .scene(entry.scene?.folder)
    }
    private func canPlay(_ entry: GalleryEntry) -> Bool {
        guard !model.isWorking else { return false }
        if let scene = entry.scene {
            return model.sceneRuntimeAvailable && scene.error == nil && scene.packageBytes > 0
        }
        return entry.video?.playable == true
    }
    private func play(_ entry: GalleryEntry) {
        guard canPlay(entry) else { return }
        Task {
            if let scene = entry.scene {
                await model.playScene(root: scene.root, name: scene.name, title: scene.title ?? scene.name, expectedBytes: scene.packageBytes)
            } else if let video = entry.video {
                await model.perform(.play(video.id))
            }
            if model.error == nil { showToast(AppStrings.text("已设为壁纸", locale: locale) + " · " + entry.title) }
        }
    }
    private func showToast(_ text: String) {
        let id = UUID()
        withAnimation(LibraryMotion.expansion(reduceMotion)) { toast = (id, text) }
        Task {
            try? await Task.sleep(for: .seconds(2.6))
            if toast?.id == id { withAnimation(LibraryMotion.expansion(reduceMotion)) { toast = nil } }
        }
    }
    private func shuffleSpotlight() {
        let current = heroEntry?.id
        guard let next = galleryEntries.filter({ $0.id != current }).randomElement() else { return }
        selectedSceneName = nil; model.selected = nil; focusedWallpaper = nil
        spotlightID = next.id
    }
    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<11: return "早上好"
        case 11..<18: return "下午好"
        case 18..<23: return "晚上好"
        default: return "夜深了"
        }
    }
    private func heroBanner(_ entry: GalleryEntry) -> some View {
        let playing = isPlaying(entry)
        let selected = entry.id == (selectedSceneName ?? model.selected)
        let detail: String
        if let video = entry.video {
            detail = "\(video.width) × \(video.height) · " + String(format: "%.0f FPS", video.fps)
        } else {
            detail = ByteCountFormatter.string(fromByteCount: entry.scene?.packageBytes ?? 0, countStyle: .file)
        }
        let artwork: HeroArtworkSource? = entry.scene.map { .scene(package: URL(fileURLWithPath: $0.packagePath)) }
            ?? entry.video.flatMap { $0.playable ? .video($0.url) : nil }
        return HeroBanner(identity: entry.id,
                          eyebrow: playing ? "正在桌面播放" : selected ? "已选择" : greeting,
                          eyebrowSymbol: playing ? "waveform" : selected ? "checkmark.circle.fill" : "sparkles",
                          title: entry.title, kind: entry.scene != nil ? "动态场景" : "动态视频",
                          kindSymbol: entry.scene != nil ? "square.3.layers.3d" : "play.rectangle",
                          detail: detail, playing: playing, canPlay: canPlay(entry), showsDetailsButton: !selected,
                          artwork: artwork, fallback: coverSource(entry),
                          play: { play(entry) },
                          showDetails: { selectGalleryItem(id: entry.id, isScene: entry.scene != nil) },
                          shuffle: galleryEntries.count > 1 ? shuffleSpotlight : nil)
    }
    /// Floating filter bar; pinned while the grid scrolls under it.
    private func libraryHeader(_ entries: [GalleryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("壁纸显示", selection: $showHidden) {
                    Text("可见壁纸").tag(false)
                    Text("已隐藏").tag(true)
                }.pickerStyle(.segmented).frame(width: 200).labelsHidden()
                    .accessibilityIdentifier("library.visibilityFilter")
                Picker("类型", selection: $kindFilter.animation(LibraryMotion.expansion(reduceMotion))) {
                    ForEach(LibraryKindFilter.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
                }.pickerStyle(.segmented).fixedSize().labelsHidden()
                    .accessibilityIdentifier("library.kindFilter")
                Text("\(entries.count) " + AppStrings.text("项", locale: locale)).foregroundStyle(.secondary).monospacedDigit()
                    .contentTransition(.numericText())
                if !query.isEmpty {
                    Button("清除搜索") { search = "" }.buttonStyle(.link)
                        .accessibilityIdentifier("library.clearSearch")
                }
                Spacer(minLength: 8)
                if catalog.scanning { ProgressView().controlSize(.small).help(AppStrings.text("正在检查素材…", locale: locale)) }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.grid.3x3").font(.system(size: 10)).foregroundStyle(.secondary)
                        Slider(value: $cardScale, in: 0.8...1.4).frame(width: 90).controlSize(.mini)
                            .accessibilityLabel(AppStrings.text("卡片大小", locale: locale))
                        Image(systemName: "square.grid.2x2").font(.system(size: 12)).foregroundStyle(.secondary)
                    }.help(AppStrings.text("卡片大小", locale: locale))
                    EmptyView()
                }
                Button(LocalizedStringKey(isSelecting ? "完成选择" : "批量管理")) {
                    isSelecting.toggle(); batchSelection.clear()
                    selectedSceneName = nil; model.selected = nil
                }.accessibilityIdentifier("library.batchMode")
            }
            if isSelecting {
                LibraryBatchBar(selectedCount: batchEntries.count, hidden: showHidden,
                    canDelete: batchEntries.contains { !MaterialRemoval.isBundled(URL(fileURLWithPath: $0.id)) },
                    canRotate: batchEntries.contains { $0.rotationWallpaper != nil } && !showHidden,
                    busy: model.isWorking || workshop.busy,
                    selectAll: { batchSelection.selectAll(entries.map(\.id)) }, clear: { batchSelection.clear() },
                    changeVisibility: { updateVisibility(batchEntries, hidden: !showHidden) },
                    remove: prepareBatchTrash, rotate: { addToRotation(batchEntries) })
            }
            if let batchMessage {
                HStack {
                    Text(AppStrings.text(batchMessage, locale: locale)).font(.callout).textSelection(.enabled)
                    Spacer()
                    if let undo = visibilityUndo {
                        Button("撤销") {
                            collection.setHidden(undo.hidden, ids: undo.ids)
                            visibilityUndo = nil; self.batchMessage = nil
                        }.buttonStyle(.link).accessibilityIdentifier("library.undoVisibility")
                    }
                    Button("关闭提示", systemImage: "xmark") { self.batchMessage = nil; visibilityUndo = nil }
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                }
            }
            if showHidden {
                Text("隐藏只影响图库显示；文件保留，所选轮播会跳过隐藏项。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let sceneError {
                Label(AppStrings.text(sceneError, locale: locale), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glassSurface(cornerRadius: 14, material: .bar)
        .padding(.horizontal, galleryInset).padding(.top, 10).padding(.bottom, 14)
    }
    private var unifiedLibrary: some View {
        let entries = galleryEntries
        let hero = showsHero ? heroEntry : nil
        let inspectorID = isSelecting ? nil : selectedSceneName ?? model.selected
        return HStack(spacing: 0) {
            Group {
                if entries.isEmpty && !catalog.scanning {
                    VStack(spacing: 0) {
                        libraryHeader(entries)
                        ContentUnavailableView {
                            Label(LocalizedStringKey(!query.isEmpty ? "没有匹配的壁纸" : showHidden ? "没有隐藏的壁纸" : "还没有壁纸"), systemImage: "photo.on.rectangle")
                        } description: {
                            Text(LocalizedStringKey(!query.isEmpty ? "试试其他关键词，或清除搜索查看全部壁纸。" : showHidden ? "在卡片右键菜单或批量管理中隐藏壁纸，可在这里恢复。" : "添加素材文件夹，自动识别场景和 MP4 视频。"))
                        } actions: {
                            if query.isEmpty && !showHidden {
                                Button("添加素材文件夹", action: chooseSceneDirectory).buttonStyle(.borderedProminent)
                                Button("浏览创意工坊") { page = .workshop }
                            } else if !query.isEmpty {
                                Button("清除搜索") { search = "" }
                            }
                            if kindFilter != .all {
                                Button("显示全部类型") { kindFilter = .all }
                            }
                        }
                    }
                } else {
                    GeometryReader { geometry in
                        // Reserve space for a non-overlay macOS scroll bar as well.
                        let usableWidth = max(1, geometry.size.width - galleryInset * 2 - 16)
                        let columnCount = max(1, Int((usableWidth + galleryGap) / (galleryCardWidth * cardScale + galleryGap)))
                        let cardWidth = min(galleryMaximumCardWidth * cardScale, (usableWidth - CGFloat(columnCount - 1) * galleryGap) / CGFloat(columnCount))
                        let gridWidth = cardWidth * CGFloat(columnCount) + CGFloat(columnCount - 1) * galleryGap
                        let columns = Array(repeating: GridItem(.fixed(cardWidth), spacing: galleryGap, alignment: .top), count: columnCount)
                        let heroHeight = min(360, max(220, geometry.size.width * 0.38))
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                                    if let hero {
                                        heroBanner(hero).frame(height: heroHeight)
                                            .padding(.horizontal, galleryInset).padding(.top, 14)
                                            .transition(.opacity)
                                    }
                                    Section {
                                        LazyVGrid(columns: columns, alignment: .leading, spacing: galleryGap) {
                                            ForEach(entries) { entry in
                                                Group {
                                                    if let scene = entry.scene { sceneCard(scene) }
                                                    else if let video = entry.video {
                                                        VideoCard(item: video, selected: isSelecting ? batchSelection.ids.contains(video.id) : selectedSceneName == nil && model.selected == video.id,
                                                            playing: model.stateIssue == nil && model.state.running && model.state.currentPath == video.id, selecting: isSelecting,
                                                            quickAction: canPlay(entry) ? { play(entry) } : nil) {
                                                            selectGalleryItem(id: video.id, isScene: false)
                                                        }
                                                    }
                                                }.id(entry.id).focused($focusedWallpaper, equals: entry.id)
                                                    .onMoveCommand { moveWallpaperSelection($0, columns: columnCount) }
                                                    .contextMenu {
                                                        Button(LocalizedStringKey(showHidden ? "恢复显示" : "隐藏壁纸"), systemImage: showHidden ? "eye" : "eye.slash") {
                                                            updateVisibility([entry], hidden: !showHidden)
                                                        }
                                                        Button("加入轮播", systemImage: "arrow.triangle.2.circlepath") { addToRotation([entry]) }
                                                            .disabled(showHidden || entry.rotationWallpaper == nil || model.isWorking)
                                                        Divider()
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
                                        .padding(.horizontal, galleryInset).padding(.bottom, 24).padding(.top, 4)
                                    } header: { libraryHeader(entries) }
                                }
                                .animation(LibraryMotion.expansion(reduceMotion), value: hero == nil)
                            }.scrollIndicators(.visible).modifier(CoverScrollPerformance())
                            .onChange(of: keyboardScrollTarget) { _, id in
                                if let id { withAnimation(LibraryMotion.expansion(reduceMotion)) { proxy.scrollTo(id) } }
                            }
                        }
                    }
                }
            }.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            if let scene = selectedScene {
                sceneDetails(scene).id(scene.id).frame(width: 340)
                    .glassSurface(cornerRadius: 18)
                    .padding(.trailing, 14).padding(.vertical, 12)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            } else if let video = selectedVideo {
                videoDetails(video).id(video.id).frame(width: 340)
                    .glassSurface(cornerRadius: 18)
                    .padding(.trailing, 14).padding(.vertical, 12)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(LibraryMotion.expansion(reduceMotion), value: inspectorID == nil)
        .overlay(alignment: .top) {
            if let toast {
                Label(toast.text, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    .symbolRenderingMode(.multicolor)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassSurface(cornerRadius: 999)
                    .padding(.top, 12)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .id(toast.id)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }
    private func selectGalleryItem(id: String, isScene: Bool) {
        keyboardScrollTarget = nil
        if isSelecting || NSEvent.modifierFlags.contains(.command) {
            if !isSelecting {
                isSelecting = true
                if let previous = selectedSceneName ?? model.selected {
                    batchSelection.toggle(previous, visible: galleryEntries.map(\.id))
                }
                selectedSceneName = nil; model.selected = nil
            }
            batchSelection.toggle(id, visible: galleryEntries.map(\.id), extend: NSEvent.modifierFlags.contains(.shift))
        } else {
            selectedSceneName = isScene ? id : nil
            model.selected = isScene ? nil : id
        }
        focusedWallpaper = id
    }
    private func updateVisibility(_ entries: [GalleryEntry], hidden: Bool) {
        let ids = Set(entries.map(\.visibilityID))
        guard !ids.isEmpty else { return }
        collection.setHidden(hidden, ids: ids)
        visibilityUndo = (ids, !hidden)
        batchMessage = String(format: AppStrings.text(hidden ? "已隐藏 %d 项，可在“已隐藏”中恢复。" : "已恢复显示 %d 项。", locale: locale), ids.count)
        batchSelection.clear(); selectedSceneName = nil; model.selected = nil; focusedWallpaper = nil
    }
    private func addToRotation(_ entries: [GalleryEntry]) {
        let items = entries.compactMap(\.rotationWallpaper)
        guard !items.isEmpty else { return }
        collection.addToRotation(items)
        rotationUsesSelection = true
        page = .rotation
    }
    private func prepareBatchTrash() {
        var seen = Set<String>()
        var requests: [MaterialRemoval.Request] = []
        let entries = batchEntries
        for entry in entries {
            if let request = try? MaterialRemoval.Request(payload: URL(fileURLWithPath: entry.id), title: entry.title, roots: catalog.roots),
               seen.insert(request.id).inserted { requests.append(request) }
        }
        guard !requests.isEmpty else { model.error = "所选壁纸均不可删除，内置素材会保留。"; return }
        batchTrashPreview = BatchTrashPreview(requests: requests, skipped: entries.count - requests.count)
    }
    private func executeBatchTrash(_ requests: [MaterialRemoval.Request]) {
        let roots = catalog.roots
        batchTrashPreview = nil
        Task {
            guard !workshop.busy else { return }
            let result = await model.trashWallpapers(requests, roots: roots)
            for target in result.removed { workshop.recordRemoval(target) }
            if !result.removed.isEmpty { await catalog.didTrash(result.removed) }
            visibilityUndo = nil
            batchMessage = String(format: AppStrings.text("已移入废纸篓 %d 个项目，失败 %d 个。", locale: locale), result.removed.count, result.failures.count)
            if !result.failures.isEmpty { model.error = result.failures.joined(separator: "\n") }
            batchSelection.retain(galleryEntries.map(\.id))
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
        if !isSelecting { selectedSceneName = entry.scene?.id; model.selected = entry.video?.id }
        focusedWallpaper = entry.id
        keyboardScrollTarget = entry.id
    }

    private func sceneCard(_ item: SceneCatalogPayload.Entry) -> some View {
        let entry = GalleryEntry(id: item.id, title: item.title ?? item.name, scene: item, video: nil)
        let playing = scenePlayer.isActive && scenePlayer.package == URL(fileURLWithPath: item.packagePath)
        let title = item.title ?? item.name
        return PosterCard(title: title,
                           subtitle: ByteCountFormatter.string(fromByteCount: item.packageBytes, countStyle: .file),
                           badge: "场景", selected: isSelecting ? batchSelection.ids.contains(item.id) : selectedSceneName == item.id,
                           playing: playing, warning: item.error != nil || item.capability?.resourceInspectionAvailable == false,
                           accessibilityKind: "场景壁纸",
                           playbackStatus: playing ? scenePlayer.statusText : nil, selecting: isSelecting,
                           quickAction: canPlay(entry) ? { play(entry) } : nil) {
            selectGalleryItem(id: item.id, isScene: true)
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
                .help("关闭详情").accessibilityLabel("关闭详情").keyboardShortcut(.cancelAction)
        }
    }

    private func sceneDetails(_ item: SceneCatalogPayload.Entry) -> some View {
        let sceneRoot: URL? = item.root
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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

                if item.capability?.limitationCodes.contains("nativeGravityScene") == true {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("自动播放 · 无交互", systemImage: "sparkles").font(.headline)
                        Text("金色吸积盘 · 高等数学公式 · 引力弯曲 · 纵深星空")
                        Text(item.name == "01-Ultra" ? "极致画质 4K：3840 长边 · 高清公式 · 目标 120 FPS" : "性能优先：1600 宽 · 90 步光线积分 · 30 FPS")
                        Text("使用当前画面自动生成 Space 过渡底图。")
                    }.font(.caption).foregroundStyle(.secondary)
                } else if item.capability?.limitationCodes.contains("nativeMoonScene") == true {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("NASA 月球 · 交互光影", systemImage: "moon.stars").font(.headline)
                        Text("本地时钟 · 月球自转 · 立体光影")
                        Text("桌面：聚焦 Finder 后，按住 Option 拖动旋转、滚轮缩放；鼠标移动不跟随。")
                        Text("预览：直接拖动、滚轮缩放，双击复位；松手后继续自转。")
                        Button { MoonPreview.open(assets: item.folder.appendingPathComponent("assets")) } label: {
                            Label("打开月球交互预览", systemImage: "arrow.up.left.and.arrow.down.right")
                        }.buttonStyle(.bordered)
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
        }.scrollIndicators(.visible)
            .safeAreaInset(edge: .top, spacing: 0) {
                inspectorHeading("场景详情") { selectedSceneName = nil; focusedWallpaper = nil }
                    .padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                Button {
                    guard let sceneRoot else { return }
                    Task { await model.playScene(root: sceneRoot, name: item.name, title: item.title ?? item.name,
                                                  expectedBytes: item.packageBytes) }
                } label: { Label("设为场景壁纸", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 3) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command).help("设为场景壁纸（⌘Return）")
                    .disabled(model.isWorking || !model.sceneRuntimeAvailable || item.error != nil || item.packageBytes <= 0)
                    Text("仅更换所选屏幕的壁纸").font(.caption).foregroundStyle(.secondary)
                }.padding(16).frame(maxWidth: .infinity).background(.bar)
            }
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
                VideoCover(item: item, size: .inspector).modifier(ArtworkCrossfade(identity: item.id)).aspectRatio(4 / 3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .bottomLeading) { coverLabel("视频封面").padding(10) }
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title).font(.system(size: 17, weight: .semibold)).textSelection(.enabled)
                        .contentTransition(.opacity).animation(LibraryMotion.selection(reduceMotion), value: item.id)
                    Label("动态视频", systemImage: "play.rectangle").font(.caption).foregroundStyle(.secondary)
                }

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
        }.scrollIndicators(.visible)
            .safeAreaInset(edge: .top, spacing: 0) {
                inspectorHeading("视频详情") { model.selected = nil; focusedWallpaper = nil }
                    .padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                Button { Task { await model.perform(.play(item.id)) } } label: {
                    Label("设为动态壁纸", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 3)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command).help("设为动态壁纸（⌘Return）").disabled(model.isWorking || !item.playable)
                    Text("仅更换所选屏幕的壁纸").font(.caption).foregroundStyle(.secondary)
                }.padding(16).frame(maxWidth: .infinity).background(.bar)
            }
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
        VStack(spacing: 0) {
            if model.targetDisplayUUID == nil { Picker("轮播来源", selection: $rotationUsesSelection) {
                Text("所选壁纸").tag(true)
                Text("默认视频文件夹").tag(false)
            }.pickerStyle(.segmented).frame(maxWidth: 480).padding(16)
                .accessibilityIdentifier("rotation.source") }
            if rotationUsesSelection || model.targetDisplayUUID != nil {
                SelectionRotationView(collection: collection, draft: $selectionRotationDraft) {
                    showHidden = false; page = .library; isSelecting = true; batchSelection.clear()
                }
            } else { defaultRotationSettings }
        }
    }
    private var defaultRotationSettings: some View {
        let applied = model.stateIssue == nil && model.state.rotating
            && rotationDraft.matches(interval: model.state.interval, mode: model.state.mode)
        return Form {
            Section {
                LabeledContent("当前状态", value: AppStrings.text(model.rotationStatusText, locale: locale))
                if model.isRotating || model.stateIssue != nil { LabeledContent("当前间隔", value: AppStrings.text(model.rotationIntervalText, locale: locale)) }
            } header: { Text("状态") }
            Section {
                if let directory = model.capabilities.libraryDirectory {
                    LabeledContent("视频文件夹", value: directory.lastPathComponent)
                    Text(directory.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("在访达中显示", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                Text("仅轮播此文件夹中的视频，场景壁纸不参与轮播。")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("轮播范围") }
            Section("切换设置") {
                Picker("切换方式", selection: $rotationDraft.mode) {
                    ForEach(model.capabilities.rotationModes, id: \.self) { value in Text(LocalizedStringKey(value == "rand" ? "随机" : value == "next" ? "顺序" : "倒序")).tag(value) }
                }
                HStack {
                    Text("切换间隔")
                    Spacer()
                    TextField("", text: $rotationDraft.minutesText)
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .frame(width: 72).multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("rotation.minutes").accessibilityLabel("切换间隔（分钟）")
                    Text("分钟")
                }.accessibilityElement(children: .contain)
                HStack {
                    Text("常用间隔").foregroundStyle(.secondary)
                    Spacer()
                    ForEach([15, 30, 60, 120], id: \.self) { value in
                        Button(String(format: AppStrings.text("%.0f 分钟", locale: locale), Double(value))) { rotationDraft.minutesText = String(value) }
                            .accessibilityIdentifier("rotation.preset.\(value)")
                    }
                }
                if rotationDraft.minutes == nil {
                    Label("请输入 1-1440 之间的整数分钟。", systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.orange)
                } else {
                    Label(LocalizedStringKey(applied ? "当前设置已生效" : "修改不会自动生效，点击下方按钮后开始或更新轮播。"),
                          systemImage: applied ? "checkmark.circle" : "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button(LocalizedStringKey(model.state.rotating ? "应用更改" : "开启轮播")) {
                        guard let minutes = rotationDraft.minutes else { return }
                        Task { await model.perform(.rotation(minutes * 60, rotationDraft.mode)) }
                    }.buttonStyle(.borderedProminent)
                        .disabled(rotationDraft.minutes == nil || applied || model.capabilities.rotationModes.isEmpty)
                        .accessibilityIdentifier("rotation.apply")
                    Button("关闭轮播") { Task { await model.perform(.stopRotation) } }
                        .disabled(!model.isRotating && model.stateIssue == nil)
                    if rotationDraft.isEdited {
                        Button("还原当前设置", action: syncRotationFields).buttonStyle(.link)
                    }
                }
                if let notice = model.state.notice { Text(LocalizedStringKey(notice)).foregroundStyle(.orange) }
            }.disabled(model.isWorking)
        }.formStyle(.grouped).frame(maxWidth: 680).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var dockStatusColor: Color {
        if model.stateIssue != nil && !scenePlayer.isActive { return .orange }
        return scenePlayer.isActive || model.state.running ? .green : .secondary
    }
    /// Floating "now playing" dock: target display, status, transport and stop controls.
    private var nowPlayingDock: some View {
        HStack(spacing: 12) {
            PlaybackDot(color: dockStatusColor, active: scenePlayer.isActive || model.state.running)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(scenePlayer.applyingEffects ? "正在应用场景效果…" : model.busy ? "正在切换壁纸…" : scenePlayer.isActive || scenePlayer.phase == .failed ? scenePlayer.statusText : model.stateIssue != nil ? "状态未知" : model.state.running ? "桌面视频播放中" : "桌面待机"))
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(LocalizedStringKey(playbackSubtitle)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                if model.selectionRotation.active { Text("所选壁纸轮播中").font(.caption2).foregroundStyle(.secondary) }
            }.frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Image(systemName: "display.2").foregroundStyle(.secondary).accessibilityHidden(true)
                Picker("播放到", selection: $playback.selectedUUID) {
                    ForEach(playback.displays, id: \.uuid) { display in
                        Text(playback.label(for: display)).tag(display.uuid)
                    }
                    if playback.displays.isEmpty { Text("未连接").tag("") }
                }.labelsHidden().frame(minWidth: 130, maxWidth: 220)
                    .disabled(playback.busy).accessibilityIdentifier("playback.display")
                    .help(AppStrings.text("每块屏幕独立选择，也可使用同一张壁纸", locale: locale))
                Menu {
                    ForEach(playback.displays, id: \.uuid) { display in
                        Text(playback.label(for: display) + " · " + (playback.playingTitle(for: display) ?? AppStrings.text("未播放壁纸", locale: locale)))
                    }
                } label: { Label("各屏幕状态", systemImage: "info.circle").labelStyle(.iconOnly) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(AppStrings.text("各屏幕状态", locale: locale))
            }
            Divider().frame(height: 24)
            if selectedSceneName == nil || model.selectionRotation.active {
                HStack(spacing: 2) {
                    control("backward.end.fill", model.selectionRotation.active ? "上一张壁纸" : "上一段视频", .previous)
                    control("shuffle", model.selectionRotation.active ? "随机壁纸" : "随机视频", .random)
                    control("forward.end.fill", model.selectionRotation.active ? "下一张壁纸" : "下一段视频", .next)
                }
            }
            if scenePlayer.supportsControls {
                let pauseTitle = scenePlayer.manualPause ? "继续场景" : "暂停场景"
                Button { scenePlayer.togglePause() } label: {
                    Image(systemName: scenePlayer.manualPause ? "play.fill" : "pause.fill").font(.system(size: 12)).frame(width: 27, height: 27).contentShape(Rectangle())
                }.buttonStyle(.borderless).disabled(model.isWorking)
                    .help(AppStrings.text(pauseTitle, locale: locale)).accessibilityLabel(AppStrings.text(pauseTitle, locale: locale))
            }
            Button { Task { await model.perform(.stop) } } label: {
                Image(systemName: "stop.fill").font(.system(size: 12)).frame(width: 27, height: 27).contentShape(Rectangle())
            }.buttonStyle(.borderless)
                .help(AppStrings.text("停止所选屏幕的壁纸与轮播", locale: locale)).accessibilityLabel(AppStrings.text("停止此屏幕", locale: locale))
                .disabled(model.busy || scenePlayer.phase == .stopping || (!scenePlayer.isActive && !model.state.running && !model.selectionRotation.active && !scenePlayer.restorationPending && !model.videoBackdrop.restorationPending && model.stateIssue == nil))
            Button("停止所有壁纸") { Task { await playback.stopAll() } }
                .font(.system(size: 11, weight: .medium)).help(AppStrings.text("停止场景和视频，并关闭轮播", locale: locale))
                .disabled(playback.busy)
        }
        .controlSize(.regular)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassSurface(cornerRadius: 18)
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
            .accessibilityLabel(AppStrings.text(title, locale: locale)).disabled((!model.selectionRotation.active && model.items.isEmpty) || model.isWorking)
    }
    private func issueBanner(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 16).padding(.top, 8)
    }
    private func importVideos() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType.mpeg4Movie]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        if panel.runModal() == .OK { Task { await model.importFiles(panel.urls) } }
    }
    private func syncRotationFields() {
        rotationDraft.sync(interval: model.state.interval, mode: model.state.mode, supportedModes: model.capabilities.rotationModes)
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
private struct VideoCover: View {
    let item: Wallpaper
    var size: CoverSize = .card
    var body: some View { LibraryCover(source: .videoProject(folder: item.url.deletingLastPathComponent(), fallback: item.thumbnail), symbol: "film", size: size) }
}
private struct VideoCard: View {
    @Environment(\.locale) private var locale
    let item: Wallpaper
    let selected: Bool
    let playing: Bool
    let selecting: Bool
    let quickAction: (() -> Void)?
    let action: () -> Void
    var body: some View {
        PosterCard(title: item.title, subtitle: "\(item.width) × \(item.height)",
                    badge: String(format: AppStrings.text("%.0f 秒", locale: locale), item.duration), selected: selected,
                    playing: playing, warning: item.warning != nil || item.decodeWarning,
                    accessibilityKind: "视频壁纸", playbackStatus: playing ? "正在桌面播放" : nil,
                    selecting: selecting, quickAction: quickAction,
                    action: action) {
            VideoCover(item: item)
        }
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
