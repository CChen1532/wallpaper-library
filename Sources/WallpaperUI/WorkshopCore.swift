import Foundation

enum WorkshopFailure: Error, LocalizedError {
    case invalidLink, unavailable, wrongApp, network, responseTooLarge, unsupportedProject
    case invalidProject, unsafeFiles, componentMissing, componentInvalid, componentChanged
    case invalidAccount, loginFailed, downloadFailed, timedOut, launchFailed, busy
    case pageChanged, subscriptionLogin, subscriptionLimit
    var errorDescription: String? {
        switch self {
        case .invalidLink: return "请输入有效的创意工坊链接或数字 ID。"
        case .unavailable: return "此项目不存在、已被移除或没有公开访问权限。"
        case .wrongApp: return "此项目不属于 Wallpaper Engine。"
        case .network: return "无法连接 Steam，请检查网络后重试。"
        case .responseTooLarge: return "Steam 返回的数据过大，已停止读取。"
        case .unsupportedProject: return "当前支持场景和 MP4 视频，暂不支持网页、应用或合集。"
        case .invalidProject: return "素材不完整或项目描述无效，未加入资料库。"
        case .unsafeFiles: return "素材含有越界路径、链接或异常文件，未加入资料库。"
        case .componentMissing: return "请先准备 SteamCMD 下载组件。"
        case .componentInvalid: return "无法使用所选组件，请选择官方 SteamCMD 可执行文件。"
        case .componentChanged: return "下载组件校验失败，未安装。请稍后重试。"
        case .invalidAccount: return "请输入 Steam 登录账号；密码不能包含换行或控制字符。"
        case .loginFailed: return "Steam 登录失败，请检查账号、密码或 Steam Guard 验证。"
        case .downloadFailed: return "下载未完成。请确认账号拥有 Wallpaper Engine，并检查网络和项目访问权限。"
        case .timedOut: return "Steam 长时间没有响应，已停止任务，可以重试。"
        case .launchFailed: return "SteamCMD 无法启动。Apple 芯片 Mac 可能需要 Rosetta，请检查组件是否可运行。"
        case .busy: return "请等待当前任务完成或取消后重试。"
        case .pageChanged: return "无法识别 Steam 返回的页面，请刷新后重试。原有列表与文件已保留。"
        case .subscriptionLogin: return "请先在此窗口登录 Steam，再打开自己的订阅页面。"
        case .subscriptionLimit: return "订阅列表过大或分页异常，已停止读取，未替换原有列表。"
        }
    }
}

struct WorkshopItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let previewURL: URL?
    let bytes: Int64
    let tags: [String]
    var summary: String = ""
    var communityURL: URL { URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=" + id)! }
}

enum WorkshopMetadata {
    static func request(id: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("itemcount=1&publishedfileids%5B0%5D=\(id)".utf8)
        request.timeoutInterval = 25
        return request
    }

    static func fetch(id: String) async throws -> WorkshopItem {
        let data = try await WorkshopNetwork.read(request(id: id), maximum: 2 * 1024 * 1024)
        return try decode(data, expectedID: id)
    }

    static func fetch(ids: [String]) async throws -> [WorkshopItem] {
        var result: [WorkshopItem] = []
        for start in stride(from: 0, to: ids.count, by: 50) {
            let batch = Array(ids[start..<min(start + 50, ids.count)])
            guard batch.allSatisfy({ if case .ok = WorkshopURLParser.parse($0) { return true }; return false }) else { throw WorkshopFailure.invalidLink }
            var request = request(id: batch[0])
            request.httpBody = Data((["itemcount=\(batch.count)"] + batch.enumerated().map { "publishedfileids%5B\($0.offset)%5D=\($0.element)" }).joined(separator: "&").utf8)
            let data = try await WorkshopNetwork.read(request, maximum: 8 * 1024 * 1024)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = root["response"] as? [String: Any], let details = response["publishedfiledetails"] as? [[String: Any]] else { throw WorkshopFailure.pageChanged }
            for id in batch {
                guard let value = details.first(where: { string($0["publishedfileid"]) == id }) else { throw WorkshopFailure.pageChanged }
                if string(value["result"]) != "1" { continue }
                let single = try JSONSerialization.data(withJSONObject: ["response": ["publishedfiledetails": [value]]])
                if let item = try? decode(single, expectedID: id) { result.append(item) }
            }
        }
        return result
    }

    static func decode(_ data: Data, expectedID: String) throws -> WorkshopItem {
        guard data.count <= 2 * 1024 * 1024 else { throw WorkshopFailure.responseTooLarge }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let details = response["publishedfiledetails"] as? [[String: Any]],
              let value = details.first, string(value["publishedfileid"]) == expectedID,
              string(value["result"]) == "1" else { throw WorkshopFailure.unavailable }
        guard string(value["consumer_app_id"]) == "431960" else { throw WorkshopFailure.wrongApp }
        if string(value["file_type"]) == "2" { throw WorkshopFailure.unsupportedProject }
        let title = clean(value["title"] as? String ?? expectedID)
        let tags = (value["tags"] as? [[String: Any]] ?? []).compactMap { $0["tag"] as? String }.map(clean)
        return WorkshopItem(id: expectedID, title: title.isEmpty ? expectedID : title,
                            previewURL: preview(value["preview_url"] as? String),
                            bytes: max(0, Int64(string(value["file_size"]) ?? "0") ?? 0), tags: tags,
                            summary: clean(value["short_description"] as? String ?? value["description"] as? String ?? ""))
    }

    private static func string(_ value: Any?) -> String? {
        (value as? String) ?? (value as? NSNumber)?.stringValue
    }
    static func clean(_ value: String) -> String {
        String(value.components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
    }
    private static func preview(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              ["steamusercontent.com", "steamuserimages-a.akamaihd.net", "steamstatic.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return url
    }
}

enum WorkshopNetwork {
    static func read(_ request: URLRequest, maximum: Int) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  http.url?.scheme == "https" else { throw WorkshopFailure.network }
            guard response.expectedContentLength <= maximum else { throw WorkshopFailure.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximum else { throw WorkshopFailure.responseTooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as WorkshopFailure { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw WorkshopFailure.network }
    }
}

struct WorkshopStorage: Sendable {
    let root: URL
    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WallpaperUI/Workshop")) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }
    var library: URL { root.appendingPathComponent("Library", isDirectory: true) }
    var component: URL { root.appendingPathComponent("SteamCMD/steamcmd") }
    func destination(_ id: String) -> URL { library.appendingPathComponent(id, isDirectory: true) }

    func makeStaging() throws -> URL {
        let url = root.appendingPathComponent("Staging/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    func installed(_ id: String) -> Bool { (try? validateProject(destination(id))) != nil }

    /// Only validated, complete directories are published. Existing items retain their stable paths and per-wallpaper settings.
    func importProject(from source: URL, item: WorkshopItem, consumeStagedFiles: Bool = false) throws -> URL {
        guard case .ok = WorkshopURLParser.parse(item.id) else { throw WorkshopFailure.invalidLink }
        try Task.checkCancellation()
        try validateProject(source)
        let fm = FileManager.default
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        let target = destination(item.id)
        if fm.fileExists(atPath: target.path) {
            try validateProject(target)
            return target
        }
        let pending = library.appendingPathComponent(".incoming-" + UUID().uuidString)
        defer { try? fm.removeItem(at: pending) }
        if consumeStagedFiles {
            let stagingRoot = root.appendingPathComponent("Staging").path + "/"
            guard source.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(stagingRoot) else { throw WorkshopFailure.unsafeFiles }
            // Our download staging shares the library's volume. Avoid copying gigabytes and make cancellation prompt.
            try fm.moveItem(at: source, to: pending)
        } else {
            try fm.copyItem(at: source, to: pending)
        }
        try Task.checkCancellation()
        try validateProject(pending)
        let projectURL = pending.appendingPathComponent("project.json")
        var project = try JSONSerialization.jsonObject(with: Data(contentsOf: projectURL)) as! [String: Any]
        let title = WorkshopMetadata.clean(project["title"] as? String ?? "")
        if title.isEmpty || title.allSatisfy({ $0.isASCII && $0.isNumber }) {
            project["title"] = item.title
            try JSONSerialization.data(withJSONObject: project, options: [.prettyPrinted, .sortedKeys]).write(to: projectURL, options: .atomic)
        }
        try Task.checkCancellation()
        // A same-volume rename makes incomplete files invisible to the minute-based scanner.
        try fm.moveItem(at: pending, to: target)
        return target
    }

    func validateProject(_ folder: URL) throws {
        let fm = FileManager.default
        let base = folder.standardizedFileURL.resolvingSymlinksInPath()
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw WorkshopFailure.unsafeFiles }
        var count = 0
        var enumerationFailed = false
        guard let files = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey], errorHandler: { _, _ in enumerationFailed = true; return false }) else { throw WorkshopFailure.invalidProject }
        for case let file as URL in files {
            try Task.checkCancellation()
            count += 1
            guard count <= 20_000 else { throw WorkshopFailure.unsafeFiles }
            let v = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            guard v.isSymbolicLink != true, v.isRegularFile == true || v.isDirectory == true,
                  file.resolvingSymlinksInPath().path.hasPrefix(base.path + "/") else { throw WorkshopFailure.unsafeFiles }
        }
        guard !enumerationFailed else { throw WorkshopFailure.invalidProject }
        let metadata = base.appendingPathComponent("project.json")
        guard let size = try? metadata.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 1_048_576,
              let data = try? Data(contentsOf: metadata),
              let project = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = (project["type"] as? String)?.lowercased() else { throw WorkshopFailure.invalidProject }
        guard ["scene", "video"].contains(type) else { throw WorkshopFailure.unsupportedProject }
        let name = type == "scene" ? "scene.pkg" : (project["file"] as? String ?? "")
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"),
              !name.split(separator: "/").contains("..") else { throw WorkshopFailure.unsafeFiles }
        let payload = base.appendingPathComponent(name).standardizedFileURL
        guard payload.path.hasPrefix(base.path + "/"),
              let v = try? payload.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true,
              (v.fileSize ?? 0) > 0 else { throw WorkshopFailure.invalidProject }
        if type == "video", payload.pathExtension.lowercased() != "mp4" { throw WorkshopFailure.unsupportedProject }
    }
}
