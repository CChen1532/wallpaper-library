import Foundation

func runCatalogChecks(_ c: inout Checker) throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("wescene-catalog-test-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }
    let valid = root.appendingPathComponent("001-valid", isDirectory: true)
    let corrupt = root.appendingPathComponent("002-corrupt", isDirectory: true)
    try fm.createDirectory(at: valid, withIntermediateDirectories: false)
    try fm.createDirectory(at: corrupt, withIntermediateDirectories: false)
    let pixels = Array(repeating: [UInt8(255), UInt8(0), UInt8(0), UInt8(255)], count: 16).flatMap { $0 }
    let package = try makePreviewPackage(objects: [["id": 1, "image": "models/red.json", "origin": "2 2 0", "size": "4 4"]],
                                         textures: ["red": pixels])
    try package.write(to: valid.appendingPathComponent("scene.pkg"))
    try Data(#"{"type":"scene","title":" 演示场景 "}"#.utf8).write(to: valid.appendingPathComponent("project.json"))
    try Data([1, 2, 3]).write(to: corrupt.appendingPathComponent("scene.pkg"))
    let linked = root.appendingPathComponent("003-link", isDirectory: true)
    try fm.createSymbolicLink(at: linked, withDestinationURL: valid)
    let report = try JSONDecoder().decode(WESceneCatalogReport.self,
        from: WESceneInspection.catalog(directory: root, maxPreviewDimension: 4))
    c.check(report.entries.map(\.name) == ["001-valid", "002-corrupt"] && !report.desktopScenePlayable,
            "场景目录排序发现且不跟随链接或宣称桌面可播放")
    c.check(report.entries[0].capability?.restrictedStaticPreviewAvailable == true &&
            report.entries[0].capability?.desktopScenePlayable == false,
            "有效场景包保留受限静态预览与播放边界")
    c.check(report.entries[0].title == "演示场景" && report.entries[1].title == nil,
            "有界项目元数据读取标题，缺失时回退目录名")
    c.check(report.entries[1].capability == nil && report.entries[1].error != nil,
            "损坏场景包不阻断其余目录条目")
    var refusedLinkedRoot = false
    do { _ = try WESceneInspection.catalog(directory: linked, maxPreviewDimension: 4) }
    catch { refusedLinkedRoot = true }
    c.check(refusedLinkedRoot, "场景根目录符号链接拒绝")
}
