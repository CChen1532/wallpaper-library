import Foundation

@main struct MaterialDiscoveryChecks {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.standardizedFileURL.appendingPathComponent("WallpaperDiscovery-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var count = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1; print("PASS: " + label) }
        func file(_ path: String, _ data: String = "fixture") throws -> URL {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(data.utf8).write(to: url)
            return url.standardizedFileURL
        }
        let video = try file("mixed/movie.MP4")
        let scene = try file("mixed/scene/scene.pkg")
        _ = try file("mixed/scene/preview.mp4")
        _ = try file("mixed/scene/internal/video.mp4")
        _ = try file(".hidden/hidden.mp4")
        _ = try file("not-video.txt")
        try fm.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        var found = try MaterialDiscovery.scan(root)
        check(found.count == 2, "混合目录识别两类素材并忽略隐藏文件与场景内部视频")
        check(found.contains { $0.url.path == video.path && $0.kind == .video }, "大写MP4扩展名识别")
        check(found.contains { $0.url.path == scene.path && $0.kind == .scene }, "场景包优先于内部视频")
        _ = try file("we-video/project.json", "{\"type\":\"video\",\"file\":\"actual.mp4\"}")
        let declared = try file("we-video/actual.mp4")
        _ = try file("we-video/preview.mp4")
        found = try MaterialDiscovery.scan(root)
        check(found.filter { $0.url.path.contains("we-video") }.map { $0.url.path } == [declared.path], "WE视频项目仅添加声明视频")
        _ = try file("we-video/project.json", #"{"type":"Video","file":"actual.mp4","title":"  A\nTitle  "}"#)
        let titled = try MaterialDiscovery.scan(root).first { $0.url == declared }
        check(titled?.title == "A Title", "声明视频读取标题、兼容大小写并清理控制字符")
        check(titled?.stamp == (try MaterialDiscovery.stamp(declared)), "标题不改变媒体指纹与路径身份")
        _ = try file("we-video/project.json", #"{"type":"video","file":"actual.mp4","title":"   "}"#)
        check(try MaterialDiscovery.scan(root).first { $0.url == declared }?.title == nil, "空标题回退文件名")
        _ = try file("incomplete/project.json", "{\"type\":\"scene\"}")
        _ = try file("incomplete/preview.mp4")
        _ = try file("web/project.json", "{\"type\":\"web\"}")
        _ = try file("web/preview.mp4")
        check(try MaterialDiscovery.scan(root).count == 3, "不完整场景及Web预览不误识别视频")
        _ = try file("partial/project.json", "{invalid")
        _ = try file("partial/preview.mp4")
        check(try MaterialDiscovery.scan(root).count == 3, "未写完的项目描述不会误导入预览视频")
        let old = try MaterialDiscovery.stamp(video)
        try Data("changed-size".utf8).write(to: video)
        check(try MaterialDiscovery.stamp(video) != old, "覆盖修改使指纹失效")
        _ = try file("new.mp4")
        check(try MaterialDiscovery.scan(root).count == 4, "后续扫描发现新增文件")
        try fm.removeItem(at: video)
        check(try !MaterialDiscovery.scan(root).contains { $0.url.path == video.path }, "删除素材后重新扫描移除")
        let overlap = try MaterialDiscovery.scan(root) + MaterialDiscovery.scan(root.appendingPathComponent("mixed"))
        check(Set(overlap.map { $0.url.path }).count == 3, "重叠根目录可以按完整路径去重")
        let outside = try file("outside.mp4")
        _ = try file("escape/project.json", "{\"type\":\"video\",\"file\":\"../outside.mp4\"}")
        check(try MaterialDiscovery.scan(root.appendingPathComponent("escape")).isEmpty, "项目相对路径不能逃出自身目录")
        let backend = PhontoBackend(home: root, directoryOverride: root.appendingPathComponent("mixed"))
        do { try backend.validateLibraryFile(outside); fatalError("allowed outside root") } catch { check(true, "播放仍拒绝未登记目录") }
        print("\(count) discovery checks passed")
    }
}
