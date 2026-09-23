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
        let packageBytes: Int64
        let capability: Capability?
        let error: String?
        var id: String { name }
    }
    let entries: [Entry]
}
struct NativeLibraryView: View {
    @EnvironmentObject var model: LibraryModel
    @State private var page: LibraryPage? = .videos
    @State private var search = ""
    @State private var minutes = 60
    @State private var mode = "rand"
    @State private var confirmTrash = false
    @State private var showDiagnostics = false
    @State private var sceneRoot: URL?
    @State private var sceneEntries: [SceneCatalogPayload.Entry] = []
    @State private var sceneLoading = false
    @State private var sceneError: String?
    @FocusState private var focusedVideo: String?
    private var filtered: [Wallpaper] { model.items.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section("资料库") {
                    Label("全部视频", systemImage: "film.stack").badge(model.items.count).tag(LibraryPage.videos)
                    Label("WE 场景（只读）", systemImage: "square.3.layers.3d").tag(LibraryPage.scenes)
                }
                Section("桌面") { Label("自动轮播", systemImage: "arrow.triangle.2.circlepath").tag(LibraryPage.rotation) }
            }.listStyle(.sidebar).navigationTitle("视频壁纸")
                .navigationSplitViewColumnWidth(min: 175, ideal: 200, max: 250)
                .safeAreaInset(edge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("视频在桌面背景播放", systemImage: "desktopcomputer")
                        Text("选择视频，设为动态壁纸。").foregroundStyle(.secondary)
                    }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
        } detail: {
            VStack(spacing: 0) {
                if let issue = model.stateIssue { issueBanner("状态暂不可用：" + issue) }
                if let issue = model.libraryIssue { issueBanner("素材读取失败：" + issue) }
                if page == .rotation { rotationSettings }
                else if page == .scenes { sceneLibrary }
                else { videoLibrary }
                if page != .scenes { Divider(); desktopControls }
            }
            .navigationTitle(page == .rotation ? "自动轮播" : page == .scenes ? "WE 场景" : "全部视频")
            .navigationSubtitle(page == .rotation ? "定时切换桌面上的视频壁纸" : page == .scenes ? "只读检查，尚不可设为动态壁纸" : "\(model.items.count) 个视频")
            .searchable(text: $search, placement: .toolbar, prompt: "搜索视频")
            .toolbar {
                ToolbarItemGroup {
                    if page == .scenes {
                        Button(action: chooseSceneDirectory) { Label("选择场景目录", systemImage: "folder.badge.plus") }.disabled(sceneLoading)
                        Button { if let sceneRoot { Task { await loadScenes(from: sceneRoot) } } } label: { Label("刷新场景", systemImage: "arrow.clockwise") }.disabled(sceneLoading || sceneRoot == nil)
                    } else {
                        Button(action: importVideos) { Label("导入视频", systemImage: "plus") }.help("导入 MP4 视频").keyboardShortcut("o", modifiers: .command).disabled(model.isWorking || !model.capabilities.canImport)
                        Button { Task { await model.refreshLibrary() } } label: { Label("刷新", systemImage: "arrow.clockwise") }.help("刷新资料库").keyboardShortcut("r", modifiers: .command).disabled(model.isWorking)
                    }
                    Menu {
                        Button("打开视频文件夹", systemImage: "folder") { if let url = model.capabilities.libraryDirectory { NSWorkspace.shared.open(url) } }.disabled(model.capabilities.libraryDirectory == nil)
                        Button("显示器与运行状态", systemImage: "desktopcomputer") { showDiagnostics = true; Task { await model.refreshDiagnostics() } }
                    } label: { Label("更多", systemImage: "ellipsis.circle") }.help("更多操作")
                }
            }
        }
        .task {
            await model.refreshLibrary(); syncRotationFields()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(4)) } catch { break }
                await model.refreshState()
            }
        }
        .onChange(of: page) { _, newValue in if newValue == .rotation { syncRotationFields() } }
        .alert("操作提示", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("知道了") { model.error = nil } } message: { Text(model.error ?? "") }
        .confirmationDialog("将所选视频移入废纸篓？", isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("移入废纸篓", role: .destructive) { Task { await model.trashSelected() } }
            Button("取消", role: .cancel) {}
        } message: { Text("\(model.selectedWallpaper?.url.lastPathComponent ?? "")\n可以从废纸篓恢复。若正在播放此视频或开启了轮播，将先停止桌面播放并关闭轮播。") }
        .sheet(isPresented: $showDiagnostics) { diagnosticsSheet }
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
            Label("场景仅供检查；静态预览可用不代表可以在桌面播放。", systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
            if let sceneRoot { Text(sceneRoot.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if let sceneError { issueBanner("场景检查失败：" + sceneError) }
            if sceneLoading { ProgressView("正在只读检查场景…") }
            if sceneRoot == nil {
                ContentUnavailableView("选择场景目录", systemImage: "square.3.layers.3d",
                    description: Text("仅检查所选目录的一级子目录；不会导入、播放或更改桌面。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !sceneLoading && sceneEntries.isEmpty && sceneError == nil {
                ContentUnavailableView("没有找到 scene.pkg", systemImage: "doc.text.magnifyingglass",
                    description: Text("请检查所选目录是否包含场景子目录。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(sceneEntries) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.name).font(.headline)
                        Text(ByteCountFormatter.string(fromByteCount: item.packageBytes, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                        if let error = item.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                        else if let capability = item.capability {
                            Label(capability.restrictedStaticPreviewAvailable ? "可生成受限静态预览" : "无可合成静态预览",
                                  systemImage: capability.restrictedStaticPreviewAvailable ? "photo" : "photo.badge.exclamationmark")
                            Text("桌面动态播放未支持 · 完整效果未还原").foregroundStyle(.secondary)
                            Text("限制：" + capability.limitationCodes.joined(separator: "、"))
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }.font(.callout).padding(.vertical, 5)
                }.listStyle(.inset)
            }
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func chooseSceneDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "选择包含 Wallpaper Engine 场景子目录的文件夹（只读）"
        if panel.runModal() == .OK, let url = panel.url {
            sceneRoot = url
            sceneEntries = []
            Task { await loadScenes(from: url) }
        }
    }
    private func loadScenes(from root: URL) async {
        guard !sceneLoading else { return }
        sceneLoading = true; sceneError = nil
        defer { sceneLoading = false }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try WESceneInspection.catalog(directory: root, maxPreviewDimension: 480)
            }.value
            guard sceneRoot == root else { return }
            sceneEntries = try JSONDecoder().decode(SceneCatalogPayload.self, from: data).entries
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
                    Text(model.busy ? "正在操作…" : model.stateIssue != nil ? "状态未知" : model.state.running ? "桌面视频播放中" : "桌面视频未播放").font(.callout.weight(.medium))
                    if model.stateIssue == nil, let path = model.state.currentPath { Text(URL(fileURLWithPath: path).lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            } icon: { Image(systemName: "desktopcomputer").foregroundStyle(model.state.running ? Color.accentColor : Color.secondary) }
            Spacer(minLength: 4)
            control("backward.end", "上一段视频", .previous)
            control("shuffle", "随机视频", .random)
            control("forward.end", "下一段视频", .next)
            Divider().frame(height: 20)
            Button("停止桌面播放") { Task { await model.perform(.stop) } }.help("停止视频播放，保留自动轮播设置")
            Button("全部关闭") { Task { await model.perform(.off) } }.help("停止桌面视频并关闭轮播")
        }.padding(.horizontal, 20).padding(.vertical, 12).disabled(model.isWorking).background(Color(nsColor: .windowBackgroundColor))
    }
    private func control(_ icon: String, _ title: String, _ action: Action) -> some View { Button { Task { await model.perform(action) } } label: { Image(systemName: icon) }.help(title).accessibilityLabel(title).disabled(model.items.isEmpty) }
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
