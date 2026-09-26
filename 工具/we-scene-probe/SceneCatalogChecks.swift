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
    try Data(#"{"type":"scene","title":" 演示\n场景 "}"#.utf8).write(to: valid.appendingPathComponent("project.json"))
    try Data([1, 2, 3]).write(to: corrupt.appendingPathComponent("scene.pkg"))
    let large = root.appendingPathComponent("003-large", isDirectory: true)
    let largeCorrupt = root.appendingPathComponent("004-large-corrupt", isDirectory: true)
    try fm.createDirectory(at: large, withIntermediateDirectories: false)
    try fm.createDirectory(at: largeCorrupt, withIntermediateDirectories: false)
    let largeBytes: UInt64 = 129 * 1024 * 1024
    for (folder, content) in [(large, package), (largeCorrupt, Data([1, 2, 3]))] {
        let path = folder.appendingPathComponent("scene.pkg")
        try content.write(to: path)
        let handle = try FileHandle(forWritingTo: path)
        try handle.truncate(atOffset: largeBytes) // Sparse: tests the size boundary without allocating 129 MiB.
        try handle.close()
    }
    let linked = root.appendingPathComponent("005-link", isDirectory: true)
    try fm.createSymbolicLink(at: linked, withDestinationURL: valid)
    let report = try JSONDecoder().decode(WESceneCatalogReport.self,
        from: WESceneInspection.catalog(directory: root, maxPreviewDimension: 4))
    c.check(report.entries.map(\.name) == ["001-valid", "002-corrupt", "003-large", "004-large-corrupt"] && !report.desktopScenePlayable,
            "场景目录排序发现且不跟随链接或宣称桌面可播放")
    c.check(report.entries[0].capability?.restrictedStaticPreviewAvailable == true &&
            report.entries[0].capability?.desktopScenePlayable == false,
            "有效场景包保留受限静态预览与播放边界")
    c.check(report.entries[0].title == "演示 场景" && report.entries[1].title == nil,
            "有界项目元数据读取标题并清理控制字符，缺失时回退目录名")
    c.check(report.entries[1].capability == nil && report.entries[1].error != nil,
            "损坏场景包不阻断其余目录条目")
    c.check(report.entries[2].packageBytes == Int64(largeBytes) && report.entries[2].error == nil &&
            report.entries[2].capability?.resourceInspectionAvailable == false &&
            report.entries[2].capability?.limitationCodes == ["largePackageInspectionDeferred"],
            "超过旧版128MiB扫描上限的包仅检查索引并可进入运行时路径")
    c.check(report.entries[3].capability == nil && report.entries[3].error != nil,
            "大型损坏包不能借延后静态分析绕过索引检查")
    var refusedLinkedRoot = false
    do { _ = try WESceneInspection.catalog(directory: linked, maxPreviewDimension: 4) }
    catch { refusedLinkedRoot = true }
    c.check(refusedLinkedRoot, "场景根目录符号链接拒绝")
}
