import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor final class LibraryModel: ObservableObject {
    @Published var items: [Wallpaper] = []
    @Published var state = PlaybackState()
    @Published var busy = false
    @Published var loading = false
    @Published var error: String?
    @Published var selected: String?
    let backend: any WallpaperBackend = PhontoBackend()
    func refreshLibrary() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do { items = try await backend.library() } catch { self.error = error.localizedDescription }
        await refreshState()
    }
    func refreshState() async {
        do { state = try await backend.state() } catch { self.error = error.localizedDescription }
    }
    func perform(_ action: Action) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try await backend.perform(action) } catch { self.error = error.localizedDescription }
        await refreshState()
    }
    func importFiles(_ urls: [URL]) async {
        guard !busy else { return }
        busy = true
        let directory = PhontoBackend().directory
        let problems = await Task.detached(priority: .utility) {
            var problems: [String] = []
            for source in urls {
                do {
                    guard source.pathExtension.lowercased() == "mp4" else { throw BackendError.message("仅支持 MP4") }
                    let destination = directory.appendingPathComponent(source.lastPathComponent)
                    guard !FileManager.default.fileExists(atPath: destination.path) else { throw BackendError.message("同名文件已存在，已跳过") }
                    try FileManager.default.copyItem(at: source, to: destination)
                } catch { problems.append(source.lastPathComponent + ": " + error.localizedDescription) }
            }
            return problems
        }.value
        if !problems.isEmpty { error = problems.joined(separator: "\n") }
        await refreshLibrary()
        busy = false
    }
    func trashSelected() async {
        guard !busy, let path = selected, items.contains(where: { $0.id == path }) else { return }
        busy = true
        defer { busy = false }
        do {
            let actual = try await backend.state()
            if actual.currentPath == path || actual.rotating { try await backend.perform(.off) }
            let url = URL(fileURLWithPath: path)
            guard url.deletingLastPathComponent().standardizedFileURL == PhontoBackend().directory.standardizedFileURL else { throw BackendError.message("素材必须位于壁纸目录中。") }
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            selected = nil
            await refreshLibrary()
        } catch { self.error = error.localizedDescription }
    }
}
@main struct WallpaperApp: App {
    @StateObject private var model = LibraryModel()
    var body: some Scene {
        WindowGroup("壁纸库") { LibraryView().environmentObject(model).preferredColorScheme(.dark).frame(minWidth: 980, minHeight: 680) }
        .defaultSize(width: 1200, height: 800)
    }
}
struct LibraryView: View {
    @EnvironmentObject var model: LibraryModel
    @State private var search = ""
    @State private var minutes = 60
    @State private var mode = "rand"
    @State private var confirmTrash = false
    private var filtered: [Wallpaper] { model.items.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                Label("壁纸库", systemImage: "square.stack.3d.up.fill").font(.title2.bold())
                VStack(alignment: .leading, spacing: 14) {
                    Label("全部壁纸", systemImage: "square.grid.2x2.fill").foregroundStyle(.mint)
                    Text("\(model.items.count) 个本地作品").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text("自动轮播").font(.headline)
                Text(model.state.rotating ? "已开启 · 每 \(model.state.interval / 60) 分钟" : "已关闭").foregroundStyle(.secondary)
                Picker("模式", selection: $mode) {
                    Text("随机").tag("rand")
                }
                Stepper("\(minutes) 分钟", value: $minutes, in: 1...1440)
                Button("应用并开启") { Task { await model.perform(.rotation(minutes * 60, mode)) } }
                Button("关闭轮播") { Task { await model.perform(.stopRotation) } }
                Spacer()
                Label("本地视频 · phonto", systemImage: "desktopcomputer").font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(width: 220).background(.white.opacity(0.035)).disabled(model.busy)
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("让桌面，流动起来。").font(.system(size: 30, weight: .semibold))
                        Text(model.state.running ? "正在播放 · \(URL(fileURLWithPath: model.state.currentPath ?? "").lastPathComponent)" : "挑选一段风景，留在桌面上。").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [UTType.mpeg4Movie]
                        panel.allowsMultipleSelection = true
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK { Task { await model.importFiles(panel.urls) } }
                    } label: { Label("导入", systemImage: "plus") }.disabled(model.busy)
                    Button { NSWorkspace.shared.open(PhontoBackend().directory) } label: { Image(systemName: "folder") }.help("打开素材目录")
                    Button { Task { await model.refreshLibrary() } } label: { Image(systemName: "arrow.clockwise") }.disabled(model.loading)
                }
                TextField("搜索壁纸", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                if model.loading { ProgressView("正在读取素材与生成预览…") }
                if !model.loading && filtered.isEmpty {
                    ContentUnavailableView("没有找到壁纸", systemImage: "photo.on.rectangle.angled", description: Text("将 MP4 文件放入素材目录，再点击刷新。"))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 18)], spacing: 20) {
                            ForEach(filtered) { item in
                                Button { model.selected = item.id } label: {
                                    VStack(alignment: .leading, spacing: 10) {
                                        ZStack(alignment: .topTrailing) {
                                            if let url = item.thumbnail, let image = NSImage(contentsOf: url) {
                                                Image(nsImage: image).resizable().scaledToFill().frame(height: 150).clipped()
                                            } else { Rectangle().fill(.white.opacity(0.07)).frame(height: 150).overlay(Image(systemName: "film").font(.largeTitle)) }
                                            if model.state.currentPath == item.id { Label("播放中", systemImage: "waveform").font(.caption.bold()).padding(7).background(.mint, in: Capsule()).foregroundStyle(.black).padding(8) }
                                        }.clipShape(RoundedRectangle(cornerRadius: 12))
                                        Text(item.title).font(.headline).lineLimit(1)
                                        Text("\(item.width) × \(item.height)  ·  \(Int(item.duration)) 秒  ·  \(item.codec.uppercased())").font(.caption).foregroundStyle(.secondary)
                                        if item.decodeWarning { Label("可能使用软件解码", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                                        if let warning = item.warning { Text(warning).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                                    }.padding(10).background(model.selected == item.id ? Color.mint.opacity(0.12) : Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
                                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(model.selected == item.id ? Color.mint : .clear, lineWidth: 1))
                                }.buttonStyle(.plain)
                            }
                        }.padding(2)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 16) {
                    Circle().fill(model.state.running ? Color.mint : .gray).frame(width: 8, height: 8)
                    Text(model.busy ? "正在操作…" : (model.state.running ? "正在播放" : "未播放")).font(.callout)
                    Spacer()
                    control("backward.end.fill", "上一张", .previous)
                    control("shuffle", "随机", .random)
                    control("forward.end.fill", "下一张", .next)
                    Button("播放所选") { if let path = model.selected { Task { await model.perform(.play(path)) } } }.buttonStyle(.borderedProminent).tint(.mint).disabled(model.selected == nil)
                    Button("停止") { Task { await model.perform(.stop) } }.help("停止当前播放，保留轮播；轮播仍可能再次启动壁纸")
                    Button("全部关闭") { Task { await model.perform(.off) } }.help("停止播放并关闭轮播")
                    Button { confirmTrash = true } label: { Image(systemName: "trash") }.disabled(model.selected == nil).help("移入废纸篓")
                }.disabled(model.busy).padding(16).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
            }.padding(28)
        }.background(Color(red: 0.055, green: 0.065, blue: 0.08))
        .task {
            await model.refreshLibrary()
            minutes = max(1, model.state.interval / 60); mode = model.state.mode
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(4)) } catch { break }
                if !model.busy { await model.refreshState() }
            }
        }
        .alert("操作提示", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("知道了") { model.error = nil } } message: { Text(model.error ?? "") }
        .confirmationDialog("将所选壁纸移入废纸篓？", isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("移入废纸篓", role: .destructive) { Task { await model.trashSelected() } }
            Button("取消", role: .cancel) {}
        } message: { Text("\(URL(fileURLWithPath: model.selected ?? "").lastPathComponent)\n可以从废纸篓恢复。若正在播放此文件或开启了轮播，将先停止播放并关闭轮播。") }
    }
    private func control(_ icon: String, _ title: String, _ action: Action) -> some View {
        Button { Task { await model.perform(action) } } label: { Image(systemName: icon) }.help(title).disabled(model.items.isEmpty)
    }
}
