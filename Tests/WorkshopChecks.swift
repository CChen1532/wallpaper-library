import Foundation
import Darwin

final class WorkshopEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [WorkshopSteamEvent] = []
    func append(_ value: WorkshopSteamEvent) { lock.withLock { values.append(value) } }
    func contains(_ value: WorkshopSteamEvent) -> Bool { lock.withLock { values.contains(value) } }
    var progress: [WorkshopDownloadProgress] { lock.withLock { values.compactMap { if case .transfer(let value) = $0 { return value }; return nil } } }
}

@main struct WorkshopChecks {
    static func main() async throws {
        setbuf(stdout, nil)
        var count = 0
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, label); count += 1; print("PASS: " + label)
        }
        func valid(_ input: String, _ id: UInt64 = 123) -> Bool {
            if case .ok(let value, _) = WorkshopURLParser.parse(input) { return value == id }; return false
        }
        for input in ["123", " 123 \n", "https://steamcommunity.com/sharedfiles/filedetails/?id=123", "https://STEAMCOMMUNITY.COM/workshop/filedetails?id=123&searchtext=hello", "steam://url/CommunityFilePage/123"] {
            check(valid(input), "accepted ID or official URL")
        }
        for input in ["", "0", "01", "-1", "+123", "１２３", "18446744073709551616", "steam://url/CommunityFilePage/", "https://steamcommunity.com.evil.test/sharedfiles/filedetails/?id=123", "https://user@steamcommunity.com/sharedfiles/filedetails/?id=123", "https://steamcommunity.com:444/sharedfiles/filedetails/?id=123", "https://steamcommunity.com/sharedfiles/filedetails/?id=123&id=124", "https://steamcommunity.com/sharedfiles/filedetails/?id=%2B123", "https://steamcommunity.com/other/?id=123", String(repeating: "1", count: 5000)] {
            check(!valid(input), "reject invalid or ambiguous URL")
        }
        check(WorkshopURLParser.parseAll("123,123\nhttps://steamcommunity.com/sharedfiles/filedetails/?id=123").count == 1, "deduplicate IDs across URL forms")

        func payload(_ fields: [String: Any] = [:]) throws -> Data {
            var detail: [String: Any] = ["publishedfileid": "123", "result": 1, "consumer_app_id": 431960, "title": "  Test\nWallpaper  ", "file_size": "4096", "file_type": 0, "preview_url": "https://steamusercontent.com/preview.png"]
            fields.forEach { detail[$0] = $1 }
            return try JSONSerialization.data(withJSONObject: ["response": ["publishedfiledetails": [detail]]])
        }
        let item = try WorkshopMetadata.decode(payload(), expectedID: "123")
        check(item.title == "Test Wallpaper" && item.bytes == 4096, "normalize metadata title and numeric strings")
        check(item.previewURL != nil, "allow Steam preview CDN")
        check(try WorkshopMetadata.decode(payload(["preview_url": "http://127.0.0.1/private"]), expectedID: "123").previewURL == nil, "ignore unsafe preview URL")
        for fields: [String: Any] in [["result": 9], ["consumer_app_id": 730], ["publishedfileid": "124"], ["file_type": 2]] {
            do { _ = try WorkshopMetadata.decode(payload(fields), expectedID: "123"); fatalError("invalid metadata accepted") }
            catch { check(true, "reject unavailable, wrong app, mismatched ID or collection") }
        }
        do { _ = try WorkshopMetadata.decode(Data("<html>error</html>".utf8), expectedID: "123"); fatalError("HTML accepted") }
        catch { check(true, "reject malformed server response") }
        check(String(decoding: WorkshopMetadata.request(id: "123").httpBody!, as: UTF8.self).contains("publishedfileids%5B0%5D=123"), "public details request needs no API key")

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("WorkshopChecks-" + UUID().uuidString).standardizedFileURL.resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let storage = WorkshopStorage(root: root.appendingPathComponent("App"))
        let logExecutable = root.appendingPathComponent("log-boundary-steamcmd")
        try fm.copyItem(at: URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Tests/Fixtures/workshop-log-boundary-fixture.py"), to: logExecutable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: logExecutable.path)
        func logBoundaryChecks(_ scenario: String) async throws {
            let worker = WorkshopSteamProcess(), stage = try storage.makeStaging(), events = WorkshopEventLog()
            let id: String
            switch scenario {
            case "unicode": id = "720"
            case "long": id = "721"
            case "old-prompt": id = "722"
            case "login": id = ""
            default: fatalError("unknown log-boundary fixture case")
            }
            if scenario == "old-prompt" {
                do {
                    _ = try await worker.download(binary: logExecutable, account: "cached_user", password: "", id: id,
                                                  staging: stage, timeout: 0.5, keepAlive: true) { _ in }
                    fatalError("prompt before current success completed the command")
                } catch WorkshopFailure.timedOut {
                    check(true, "a stale prompt before current success cannot complete the item")
                }
                let pid = Int32(try String(contentsOf: stage.appendingPathComponent("child.pid"), encoding: .utf8))!
                check(kill(pid, 0) == -1, "missing current success-to-prompt boundary closes its child")
                return
            }
            if scenario == "login" {
                try await worker.connect(binary: logExecutable, account: "long_login_user", staging: stage, timeout: 3) { events.append($0) }
                check(!fm.fileExists(atPath: stage.appendingPathComponent("steamapps").path),
                      "login completion survives long logs before its split command prompt")
            } else {
                let result = try await worker.download(binary: logExecutable, account: "cached_user", password: "", id: id,
                                                       staging: stage, timeout: 3, keepAlive: true) { events.append($0) }
                try storage.validateProject(result)
                if scenario == "unicode" {
                    check(events.progress.contains { $0.fraction == 0.375 } && events.progress.last?.fraction == 1,
                          "Unicode case expansion before the download marker preserves progress and completion")
                } else {
                    check(events.progress.last?.fraction == 1,
                          "current success survives more than 8192 log characters before its split prompt")
                }
            }
            let firstPID = Int32(try String(contentsOf: stage.appendingPathComponent("child.pid"), encoding: .utf8))!
            let next = try await worker.download(binary: logExecutable, account: scenario == "login" ? "long_login_user" : "cached_user",
                                                 password: "", id: "724", staging: stage, timeout: 3, keepAlive: true) { _ in }
            try storage.validateProject(next)
            check(try String(contentsOf: stage.appendingPathComponent("launches"), encoding: .utf8).split(separator: "\n").count == 1 && kill(firstPID, 0) == 0,
                  scenario + " log boundary preserves one reusable process for the next download")
            await worker.closeSession()
            check(kill(firstPID, 0) == -1, scenario + " log-boundary fixture is reaped on close")
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--log-boundary-case"), flag + 1 < CommandLine.arguments.count {
            let scenario = CommandLine.arguments[flag + 1]
            do { try await logBoundaryChecks(scenario) }
            catch { print("LOG BOUNDARY FAILURE " + scenario + ": " + String(describing: error)); exit(1) }
            print("\(count) targeted Workshop checks passed")
            return
        }
        func fixture(_ name: String, type: String = "video", file: String = "movie.mp4") throws -> URL {
            let folder = root.appendingPathComponent(name)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let project: [String: Any] = ["type": type, "file": file, "title": "123"]
            try JSONSerialization.data(withJSONObject: project).write(to: folder.appendingPathComponent("project.json"))
            try Data("fixture".utf8).write(to: folder.appendingPathComponent(type == "scene" ? "scene.pkg" : "movie.mp4"))
            return folder
        }
        let source = try fixture("valid")
        let imported = try storage.importProject(from: source, item: item)
        check(imported == storage.destination("123") && storage.installed("123"), "validated project committed to stable ID folder")
        let description = try JSONSerialization.jsonObject(with: Data(contentsOf: imported.appendingPathComponent("project.json"))) as! [String: Any]
        check(description["title"] as? String == item.title, "numeric title replaced by Workshop title")
        try Data("changed".utf8).write(to: source.appendingPathComponent("movie.mp4"))
        check(try storage.importProject(from: source, item: item) == imported, "same ID does not create another item")
        check(try String(contentsOf: imported.appendingPathComponent("movie.mp4"), encoding: .utf8) == "fixture", "existing imported files not overwritten")
        check(try fm.contentsOfDirectory(atPath: storage.library.path) == ["123"], "no incomplete folders published")
        try storage.validateProject(fixture("scene", type: "scene"))
        check(true, "scene project accepted")
        for (name, type, file) in [("web", "web", "index.html"), ("escape", "video", "../movie.mp4"), ("absolute", "video", "/movie.mp4"), ("missing", "video", "missing.mp4"), ("other", "video", "movie.webm")] {
            do { try storage.validateProject(fixture(name, type: type, file: file)); fatalError("invalid project accepted") }
            catch { check(true, "reject unsupported or incomplete project") }
        }
        let linked = try fixture("linked")
        try fm.createSymbolicLink(at: linked.appendingPathComponent("linked-secret"), withDestinationURL: source)
        do { try storage.validateProject(linked); fatalError("link accepted") }
        catch { check(true, "reject nested symbolic links") }
        let empty = try fixture("empty")
        try Data().write(to: empty.appendingPathComponent("movie.mp4"))
        do { try storage.validateProject(empty); fatalError("empty media accepted") }
        catch { check(true, "reject zero-byte media") }
        let cancelledImport = Task { () throws -> URL in
            withUnsafeCurrentTask { $0?.cancel() }
            return try storage.importProject(from: source, item: .init(id: "999", title: "cancel", previewURL: nil, bytes: 0, tags: []))
        }
        do { _ = try await cancelledImport.value; fatalError("cancelled import committed") }
        catch { check(!storage.installed("999"), "cancellation before import leaves library unchanged") }

        let password = "fixture; $(never-run) \"password\""
        check(WorkshopSteamProcess.validCredentials(account: "test_user", password: password), "password special characters accepted as data")
        check(!WorkshopSteamProcess.validCredentials(account: "test", password: "bad\n+quit"), "reject control-character input")
        check(!WorkshopSteamProcess.validCredentials(account: "user +quit", password: "x"), "reject ambiguous login account")
        check(!WorkshopSteamProcess.arguments(account: "test_user", id: "101", staging: root).contains(password), "password never placed in argv")
        check(WorkshopSteamProcess.progress(in: "progress: 20.1\nprogress: 37.5") == 0.375, "parse latest progress without inventing a percentage")
        check(WorkshopSteamProcess.progress(in: "Downloading item") == nil, "indeterminate download remains indeterminate")

        let executable = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Tests/Fixtures/workshop-steam-fixture.py")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        for id in ["101", "102", "103", "108"] {
            let stage = try storage.makeStaging(), events = WorkshopEventLog(), worker = WorkshopSteamProcess()
            let result = try await worker.download(binary: executable, account: "test_user", password: password, id: id, staging: stage, timeout: 8) { event in
                events.append(event)
                if event == .guardCode { precondition(worker.submitGuardCode("ABCDE")) }
            }
            try storage.validateProject(result)
            let added = try storage.importProject(from: result, item: .init(id: id, title: "Downloaded item", previewURL: nil, bytes: 1, tags: []), consumeStagedFiles: true)
            check(!fm.fileExists(atPath: result.path), "completed staging moved without another media copy")
            check(try MaterialDiscovery.scan(storage.library).contains { $0.url.deletingLastPathComponent() == added }, "downloaded project visible to the existing library scanner")
            check(events.contains(.signingIn), "split password prompt handled through PTY")
            check(events.progress.contains { $0.fraction == 0.375 }, "item-scoped Steam progress reaches telemetry")
            check(!events.progress.contains { $0.fraction == 0.995 }, "client update percentage does not leak into wallpaper progress")
            check(events.progress.last?.fraction == 1, "successful item reaches 100 percent")
            if id == "102" { check(events.contains(.guardCode), "interactive Steam Guard round trip") }
            if id == "103" { check(events.contains(.mobileApproval), "mobile approval status exposed") }
            if id == "108" { check(try String(contentsOf: stage.appendingPathComponent("updated"), encoding: .utf8) == "3", "two self-update exits restart automatically before download") }
            check(result.path.hasSuffix("/" + id), "download result requires success plus project files")
        }
        for id in ["106", "107"] {
            let worker = WorkshopSteamProcess(), stage = try storage.makeStaging()
            do { _ = try await worker.download(binary: executable, account: "test_user", password: password, id: id, staging: stage, timeout: 5) { _ in }; fatalError("failure treated as success") }
            catch { check(!storage.installed(id), "login/download failure never imported") }
        }
        let stage = try storage.makeStaging(), worker = WorkshopSteamProcess()
        let task = Task { try await worker.download(binary: executable, account: "test_user", password: password, id: "104", staging: stage, timeout: 6) { _ in } }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        do { _ = try await task.value; fatalError("cancel ignored") }
        catch is CancellationError { check(true, "task cancellation reaches running child") }
        let pid = Int32(try String(contentsOf: stage.appendingPathComponent("child.pid"), encoding: .utf8))!
        check(kill(pid, 0) == -1 && errno == ESRCH, "cancelled child has exited")
        let timeoutWorker = WorkshopSteamProcess(), timeoutStage = try storage.makeStaging()
        do { _ = try await timeoutWorker.download(binary: executable, account: "test_user", password: password, id: "105", staging: timeoutStage, timeout: 0.4) { _ in }; fatalError("timeout ignored") }
        catch { check(true, "timeout terminates hung child") }
        let restartWorker = WorkshopSteamProcess(), restartStage = try storage.makeStaging()
        do { _ = try await restartWorker.download(binary: executable, account: "test_user", password: password, id: "109", staging: restartStage, timeout: 5) { _ in }; fatalError("endless self-update accepted") }
        catch { check(true, "repeated self-update cannot create an infinite loop") }
        check(try String(contentsOf: restartStage.appendingPathComponent("updated"), encoding: .utf8) == "3", "self-update stops after three attempts")

        let shared = WorkshopSteamProcess(), sharedStage = try storage.makeStaging()
        func sharedDownload(_ id: String, password supplied: String = "", account: String = "test_user", timeout: TimeInterval = 3) async throws -> URL {
            try await shared.download(binary: executable, account: account, password: supplied, id: id,
                                      staging: sharedStage, timeout: timeout, keepAlive: true) { _ in }
        }
        func sharedPID() throws -> Int32 {
            Int32(try String(contentsOf: sharedStage.appendingPathComponent("child.pid"), encoding: .utf8))!
        }
        let firstStart = Date()
        _ = try await sharedDownload("201", password: password)
        let firstTime = Date().timeIntervalSince(firstStart), firstPID = try sharedPID()
        check(kill(firstPID, 0) == 0, "successful interactive download keeps session alive")
        let nextStart = Date()
        let next = try await sharedDownload("202")
        let nextTime = Date().timeIntervalSince(nextStart)
        try storage.validateProject(next)
        check(try sharedPID() == firstPID, "second item reuses PID and requires no password or login")
        print("FIXTURE TIMING cold=\(firstTime)s reused=\(nextTime)s (not real Steam timing)")
        do { _ = try await sharedDownload("107"); fatalError("interactive error accepted") }
        catch { check(kill(firstPID, 0) == -1, "interactive download failure closes session promptly") }
        _ = try await sharedDownload("203", password: password)
        let recoveryPID = try sharedPID()
        check(recoveryPID != firstPID, "next attempt creates a fresh session after failure")
        _ = try await sharedDownload("204", password: password, account: "other_user")
        let changedPID = try sharedPID()
        check(changedPID != recoveryPID && kill(recoveryPID, 0) == -1, "account change closes previous authenticated process")
        await shared.closeSession()
        check(kill(changedPID, 0) == -1, "shutdown reaps idle interactive process")
        _ = try await sharedDownload("205", password: password)
        let promptPID = try sharedPID()
        do { _ = try await sharedDownload("111", timeout: 0.3); fatalError("prompt alone accepted") }
        catch { check(kill(promptPID, 0) == -1, "old success or bare prompt cannot finish next item; timeout reaps process") }
        _ = try await sharedDownload("206", password: password)
        let cancelPID = try sharedPID()
        let sharedTask = Task { try await sharedDownload("104") }
        try await Task.sleep(for: .milliseconds(100))
        do { _ = try await sharedDownload("207"); fatalError("concurrent request accepted") }
        catch WorkshopFailure.busy { check(true, "concurrent requests cannot interleave PTY commands") }
        sharedTask.cancel()
        do { _ = try await sharedTask.value; fatalError("shared cancellation ignored") }
        catch is CancellationError { check(kill(cancelPID, 0) == -1, "cancelling reused download terminates its session") }
        _ = try await sharedDownload("208", password: password)
        check(try sharedPID() != cancelPID, "worker can recover after cancellation")
        await shared.closeSession()

        let warm = WorkshopSteamProcess(), warmStage = try storage.makeStaging()
        try await warm.connect(binary: executable, account: "cached_user", staging: warmStage) { _ in }
        let warmPID = Int32(try String(contentsOf: warmStage.appendingPathComponent("child.pid"), encoding: .utf8))!
        check(!fm.fileExists(atPath: warmStage.appendingPathComponent("steamapps").path), "preconnect authenticates without downloading any material")
        try await warm.connect(binary: executable, account: "cached_user", staging: warmStage) { _ in }
        let warmResult = try await warm.download(binary: executable, account: "cached_user", password: "", id: "301", staging: warmStage, keepAlive: true) { _ in }
        try storage.validateProject(warmResult)
        check(try String(contentsOf: warmStage.appendingPathComponent("launches"), encoding: .utf8).split(separator: "\n").count == 1,
              "repeated preconnect and first download share one authenticated process")
        await warm.closeSession()
        check(kill(warmPID, 0) == -1, "closing preconnected session reaps child")
        for account in ["test_user", "prompt_user", "failed_user"] {
            let cold = WorkshopSteamProcess(), stage = try storage.makeStaging()
            do {
                try await cold.connect(binary: executable, account: account, staging: stage, timeout: 0.5) { _ in }
                fatalError("unauthenticated connection accepted")
            } catch {
                if account == "test_user" { check(error as? WorkshopFailure == .passwordRequired, "expired cached login requests password without retaining it") }
                else { check(true, "bare prompt or failed user info never reports authenticated") }
            }
            let pid = Int32(try String(contentsOf: stage.appendingPathComponent("child.pid"), encoding: .utf8))!
            check(kill(pid, 0) == -1, "failed preconnect closes child")
        }
        let guarded = WorkshopSteamProcess(), guardStage = try storage.makeStaging(), guardEvents = WorkshopEventLog()
        try await guarded.connect(binary: executable, account: "guard_user", password: password, staging: guardStage) { event in
            guardEvents.append(event)
            if event == .guardCode { _ = guarded.submitGuardCode("ABCDE") }
        }
        check(guardEvents.contains(.guardCode), "preconnect supports interactive Steam Guard")
        await guarded.closeSession()
        let mobile = WorkshopSteamProcess(), mobileStage = try storage.makeStaging(), mobileEvents = WorkshopEventLog()
        try await mobile.connect(binary: executable, account: "mobile_user", password: password, staging: mobileStage) { mobileEvents.append($0) }
        check(mobileEvents.contains(.mobileApproval), "preconnect exposes phone confirmation")
        await mobile.closeSession()

        let cleanupWorker = WorkshopSteamProcess(), cleanupStage = try storage.makeStaging()
        for _ in 0..<8 {
            try await cleanupWorker.connect(binary: executable, account: "cached_user", staging: cleanupStage) { _ in }
            let pid = Int32(try String(contentsOf: cleanupStage.appendingPathComponent("child.pid"), encoding: .utf8))!
            let began = Date()
            await cleanupWorker.closeSession()
            check(Date().timeIntervalSince(began) < 3 && kill(pid, 0) == -1,
                  "idle session shutdown stays bounded across serial-queue thread reuse")
        }

        for scenario in ["unicode", "long", "old-prompt", "login"] { try await logBoundaryChecks(scenario) }

        if CommandLine.arguments.contains("--live") {
            let live = try await WorkshopMetadata.fetch(id: "1000000001")
            check(live.id == "1000000001" && !live.title.isEmpty, "real Steam public metadata request")
            print("LIVE ITEM: " + live.title)
            let binary = try await WorkshopComponent.install(storage: storage)
            check(WorkshopComponent.validBinary(binary), "real Valve archive downloaded, SHA256 checked and unpacked")
            check(try await WorkshopComponent.install(storage: storage) == binary, "component preparation preserves existing valid binary")
        }
        print("\(count) Workshop checks passed")
    }
}
