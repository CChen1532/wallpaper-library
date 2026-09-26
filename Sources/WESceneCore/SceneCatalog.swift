import Foundation
import Darwin

struct WESceneCatalogEntry: Codable {
    let name: String
    let title: String?
    let packagePath: String
    let packageBytes: Int64
    let capability: WESceneCapabilityReport?
    let error: String?
}

struct WESceneCatalogReport: Codable {
    let schemaVersion: Int
    let root: String
    let desktopScenePlayable: Bool
    let entries: [WESceneCatalogEntry]
}

extension WESceneInspection {
    private static let deepInspectionMaxBytes: Int64 = 128 * 1024 * 1024

    /// Check only the PKGV index for a large package. The older resource and
    /// preview analyzers copy the entire package into byte arrays, so they
    /// must not run just because the UI permits a larger runtime input.
    private static func largePackageVersion(at url: URL, expectedBytes: Int64) throws -> String {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ProbeError.invalid("无法安全打开大型场景包") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              Int64(metadata.st_size) == expectedBytes else {
            throw ProbeError.invalid("大型场景包已变化或不是普通文件")
        }
        let maxIndexBytes = 16 * 1024 * 1024
        var consumed = 0
        func readExactly(_ count: Int) throws -> [UInt8] {
            guard count >= 0, count <= maxIndexBytes - consumed else {
                throw ProbeError.invalid("大型场景包索引超过16MiB")
            }
            var bytes = Data()
            while bytes.count < count {
                let chunk = try handle.read(upToCount: count - bytes.count) ?? Data()
                guard !chunk.isEmpty else { throw ProbeError.truncated("大型场景包索引") }
                bytes.append(chunk)
            }
            consumed += count
            return Array(bytes)
        }
        func readInt32() throws -> Int32 {
            let bytes = try readExactly(4)
            let value = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 |
                UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Int32(bitPattern: value)
        }
        let versionLength = Int(try readInt32())
        guard (4...32).contains(versionLength),
              let version = String(bytes: try readExactly(versionLength), encoding: .utf8),
              version.hasPrefix("PKGV") else {
            throw ProbeError.invalid("大型场景包缺少有效 PKGV 标识")
        }
        let count = Int(try readInt32())
        guard (0...100_000).contains(count) else { throw ProbeError.invalid("大型场景包条目数异常") }
        var ranges: [(offset: Int64, length: Int64)] = []
        ranges.reserveCapacity(count)
        var names: Set<String> = []
        for index in 0..<count {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            let pathLength = Int(try readInt32())
            guard (1...4096).contains(pathLength),
                  let path = String(bytes: try readExactly(pathLength), encoding: .utf8),
                  safePackagePath(path),
                  names.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw ProbeError.invalid("大型场景包资源路径无效或重复")
            }
            let offset = Int64(try readInt32())
            let length = Int64(try readInt32())
            guard offset >= 0, length >= 0 else { throw ProbeError.invalid("大型场景包条目范围无效") }
            ranges.append((offset, length))
        }
        let dataBytes = expectedBytes - Int64(consumed)
        guard ranges.allSatisfy({ $0.offset <= dataBytes && $0.length <= dataBytes - $0.offset }) else {
            throw ProbeError.truncated("大型场景包资源范围越界")
        }
        guard names.contains("scene.json") else {
            throw ProbeError.invalid("大型场景包缺少 scene.json")
        }
        return version
    }

    private static func sceneTitle(in folder: URL) -> String? {
        let project = folder.appendingPathComponent("project.json", isDirectory: false)
        guard let values = try? project.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, (1...1_048_576).contains(size),
              let data = try? Data(contentsOf: project, options: .mappedIfSafe),
              (1...1_048_576).contains(data.count),
              let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              metadata["type"] as? String == "scene",
              let raw = metadata["title"] as? String else { return nil }
        let clean = raw.components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        return String(clean.prefix(160))
    }

    /// One directory level only; no symlinks, writes, scripts, or desktop operations.
    public static func catalog(directory: URL, maxPreviewDimension: Int = 640) throws -> Data {
        guard (1...960).contains(maxPreviewDimension) else {
            throw ProbeError.invalid("场景目录预览最长边必须在1...960")
        }
        let fm = FileManager.default
        let rootValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw ProbeError.invalid("场景根目录必须是真实目录，不跟随符号链接")
        }
        let children = try fm.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        guard children.count <= 1000 else { throw ProbeError.invalid("场景根目录条目超过1000") }
        var packages: [(String, String?, URL, Int64)] = []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try Task.checkCancellation()
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let pkg = child.appendingPathComponent("scene.pkg", isDirectory: false)
            guard fm.fileExists(atPath: pkg.path) else { continue }
            let pkgValues = try pkg.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard pkgValues.isRegularFile == true, pkgValues.isSymbolicLink != true else { continue }
            let bytes = Int64(pkgValues.fileSize ?? -1)
            packages.append((child.lastPathComponent, sceneTitle(in: child), pkg, bytes))
        }
        guard packages.count <= 20 else { throw ProbeError.invalid("场景包数量超过20") }
        var entries: [WESceneCatalogEntry] = []
        for (name, title, pkg, bytes) in packages {
            try Task.checkCancellation()
            guard bytes > 0 else {
                entries.append(.init(name: name, title: title, packagePath: pkg.path, packageBytes: bytes,
                                     capability: nil, error: "场景包为空"))
                continue
            }
            do {
                if bytes > deepInspectionMaxBytes {
                    let version = try largePackageVersion(at: pkg, expectedBytes: bytes)
                    let capability = WESceneCapabilityReport(schemaVersion: 1, packageVersion: version,
                        resourceInspectionAvailable: false, restrictedStaticPreviewAvailable: false,
                        desktopScenePlayable: false, faithfulSceneRendering: false,
                        previewFailure: "大型场景包不进入旧版受限静态预览",
                        limitationCodes: ["largePackageInspectionDeferred"],
                        description: "已验证包索引；跳过会复制整包的离线分析，可交给场景运行时尝试播放")
                    entries.append(.init(name: name, title: title, packagePath: pkg.path, packageBytes: bytes,
                                         capability: capability, error: nil))
                    continue
                }
                let data = try Data(contentsOf: pkg, options: .mappedIfSafe)
                guard data.count > 0 && data.count <= deepInspectionMaxBytes else {
                    throw ProbeError.invalid("读取后的场景包大小超出1...128MiB范围")
                }
                let report = try capabilityReport(packageData: data, maxPreviewDimension: maxPreviewDimension)
                let capability = try JSONDecoder().decode(WESceneCapabilityReport.self, from: report)
                entries.append(.init(name: name, title: title, packagePath: pkg.path, packageBytes: bytes,
                                     capability: capability, error: nil))
            } catch is CancellationError { throw CancellationError() }
            catch {
                entries.append(.init(name: name, title: title, packagePath: pkg.path, packageBytes: bytes,
                                     capability: nil, error: String(describing: error)))
            }
        }
        let report = WESceneCatalogReport(schemaVersion: 1, root: directory.path,
                                          desktopScenePlayable: false, entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }
}
