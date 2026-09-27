import Foundation
import CryptoKit
import Darwin

enum WorkshopComponent {
    // Valve's macOS bootstrap archive, checked against the HTTPS source on 2026-09-27.
    // Refuse a changed archive until its contents have been reviewed and this pin updated.
    static let bootstrapSHA256 = "8ecc17c8988e5acadcc78e631c48490f76150f2dfaa6cf8d7b4b67b097bd753b"
    static let bootstrapURL = URL(string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz")!

    static func validBinary(_ url: URL) -> Bool {
        guard url.lastPathComponent == "steamcmd", FileManager.default.isExecutableFile(atPath: url.path),
              let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        guard let magic = try? file.read(upToCount: 4) else { return false }
        return [[0xcf, 0xfa, 0xed, 0xfe], [0xce, 0xfa, 0xed, 0xfe], [0xca, 0xfe, 0xba, 0xbe], [0xca, 0xfe, 0xba, 0xbf]].contains(Array(magic))
    }

    static func locate(storage: WorkshopStorage, custom: String?) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let choices = [custom.map { URL(fileURLWithPath: $0) }, storage.component,
                       URL(fileURLWithPath: "/opt/homebrew/bin/steamcmd"), URL(fileURLWithPath: "/usr/local/bin/steamcmd"),
                       home.appendingPathComponent("Steam/steamcmd"), home.appendingPathComponent("steamcmd/steamcmd")].compactMap { $0 }
        return choices.first { validBinary($0.resolvingSymlinksInPath()) }?.resolvingSymlinksInPath()
    }

    static func install(storage: WorkshopStorage) async throws -> URL {
        let archive = try await WorkshopNetwork.read(URLRequest(url: bootstrapURL), maximum: 8 * 1024 * 1024)
        let digest = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        guard digest == bootstrapSHA256 else { throw WorkshopFailure.componentChanged }
        let fm = FileManager.default
        let stage = try storage.makeStaging()
        defer { try? fm.removeItem(at: stage) }
        let package = stage.appendingPathComponent("bootstrap.tar.gz")
        let unpacked = stage.appendingPathComponent("unpacked")
        try archive.write(to: package)
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: false)
        // Only extract the exact, reviewed archive. No remote shell script is executed.
        let result = try await CommandRunner().run("/usr/bin/tar", ["-xzf", package.path, "-C", unpacked.path], timeout: 20)
        guard result.code == 0, validBinary(unpacked.appendingPathComponent("steamcmd")) else { throw WorkshopFailure.componentInvalid }
        try Task.checkCancellation()
        let destination = storage.component.deletingLastPathComponent()
        if fm.fileExists(atPath: destination.path) {
            if validBinary(storage.component) { return storage.component }
            throw WorkshopFailure.componentInvalid
        }
        try fm.moveItem(at: unpacked, to: destination)
        return storage.component
    }
}

enum WorkshopSteamEvent: Equatable, Sendable {
    case preparing, signingIn, guardCode, mobileApproval, downloading(Double?)
}

/// A short-lived process per download. Secrets only enter the PTY, never argv or app logs.
/// The worker serializes input and output; the main actor receives semantic events only.
final class WorkshopSteamProcess: @unchecked Sendable {
    private enum Bootstrap: Error { case restart }
    private let lock = NSLock()
    private var cancelled = false
    private var pendingCode: String?
    private var started = false

    func cancel() { lock.withLock { cancelled = true } }
    func submitGuardCode(_ code: String) -> Bool {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...10).contains(code.count), code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
        lock.withLock { pendingCode = code }
        return true
    }
    static func validCredentials(account: String, password: String) -> Bool {
        !account.isEmpty && account.count <= 64 && account.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
            && password.utf8.count <= 1024 && !password.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    func download(binary: URL, account: String, password: String, id: String, staging: URL,
                  timeout: TimeInterval = 3600, onEvent: @escaping @Sendable (WorkshopSteamEvent) -> Void) async throws -> URL {
        guard Self.validCredentials(account: account, password: password), case .ok = WorkshopURLParser.parse(id) else { throw WorkshopFailure.invalidAccount }
        let available = lock.withLock { if started { return false }; started = true; return true }
        guard available else { throw WorkshopFailure.busy }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    for attempt in 0..<3 {
                        do {
                            let result = try self.run(binary: binary, account: account, password: password,
                                                      id: id, staging: staging, timeout: timeout, onEvent: onEvent)
                            continuation.resume(returning: result); return
                        } catch Bootstrap.restart {
                            // Valve's bootstrap exits with 42 after replacing itself; its shell wrapper normally restarts it.
                            if attempt == 2 { continuation.resume(throwing: WorkshopFailure.launchFailed); return }
                        } catch { continuation.resume(throwing: error); return }
                    }
                }
            }
        }, onCancel: { self.cancel() })
    }

    static func arguments(account: String, id: String, staging: URL) -> [String] {
        ["+force_install_dir", staging.path, "+login", account,
         "+workshop_download_item", "431960", id, "+quit"]
    }

    private func run(binary: URL, account: String, password: String, id: String, staging: URL,
                     timeout: TimeInterval, onEvent: @escaping @Sendable (WorkshopSteamEvent) -> Void) throws -> URL {
        if lock.withLock({ cancelled }) { throw CancellationError() }
        var master: Int32 = -1, slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { throw WorkshopFailure.launchFailed }
        defer { close(master) }
        var ownsSlave = true
        defer { if ownsSlave { close(slave) } }
        var attributes = termios()
        guard tcgetattr(slave, &attributes) == 0 else { throw WorkshopFailure.launchFailed }
        attributes.c_lflag &= ~tcflag_t(ECHO | ECHONL)
        _ = tcsetattr(slave, TCSANOW, &attributes)
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        let process = Process()
        process.executableURL = binary
        process.currentDirectoryURL = binary.deletingLastPathComponent()
        process.arguments = Self.arguments(account: account, id: id, staging: staging)
        // Keep SteamCMD's profile away from the user's Steam client. No app credential store is created.
        let profile = staging.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Profile")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        process.environment = ["HOME": profile.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "TERM": "dumb"]
        process.standardInput = terminal; process.standardOutput = terminal; process.standardError = terminal
        do { try process.run() } catch { throw WorkshopFailure.launchFailed }
        close(slave); ownsSlave = false
        defer {
            if process.isRunning {
                process.terminate()
                let until = Date().addingTimeInterval(1)
                while process.isRunning && Date() < until { usleep(20_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
        }

        var lastEvent: WorkshopSteamEvent?
        func publish(_ event: WorkshopSteamEvent) { if lastEvent != event { lastEvent = event; onEvent(event) } }
        func send(_ value: String) throws {
            // Enforce echo-off again even if SteamCMD adjusted terminal settings.
            var state = termios()
            if tcgetattr(master, &state) == 0 { state.c_lflag &= ~tcflag_t(ECHO | ECHONL); _ = tcsetattr(master, TCSANOW, &state) }
            var bytes = Array((value + "\n").utf8)
            defer { for i in bytes.indices { bytes[i] = 0 } }
            try bytes.withUnsafeBytes { ptr in
                var offset = 0
                while offset < ptr.count {
                    let n = Darwin.write(master, ptr.baseAddress!.advanced(by: offset), ptr.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw WorkshopFailure.loginFailed }
                    offset += n
                }
            }
        }
        var transcript = "", sentPassword = false, waitingGuard = false, success = false
        let deadline = Date().addingTimeInterval(timeout)
        var lastOutput = Date()
        publish(.preparing)
        while true {
            if lock.withLock({ cancelled }) { throw CancellationError() }
            guard Date() < deadline, Date().timeIntervalSince(lastOutput) < 600 else { throw WorkshopFailure.timedOut }
            if waitingGuard, let code = lock.withLock({ let code = pendingCode; pendingCode = nil; return code }) {
                try send(code); waitingGuard = false; transcript = ""; publish(.signingIn)
            }
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready > 0 {
                var bytes = [UInt8](repeating: 0, count: 4096)
                let n = read(master, &bytes, bytes.count)
                if n <= 0 { if !process.isRunning { break }; usleep(100_000); continue }
                lastOutput = Date()
                transcript = String((transcript + String(decoding: bytes.prefix(n), as: UTF8.self)).suffix(8192))
                let lower = transcript.lowercased()
                if lower.contains("invalid password") || lower.contains("invalidpassword") || lower.contains("invalid login auth code") || lower.contains("account logon denied") {
                    throw WorkshopFailure.loginFailed
                }
                if lower.contains("success. downloaded item \(id) to ") { success = true }
                if !sentPassword && (lower.contains("password:") || lower.contains("password: ")) {
                    guard !password.isEmpty else { throw WorkshopFailure.loginFailed }
                    sentPassword = true; try send(password); transcript = ""; publish(.signingIn)
                } else if lower.contains("steam guard code:") || lower.contains("two-factor code:") || lower.contains("authenticator code:") || lower.contains("enter the current code") || lower.contains("enter the code") {
                    waitingGuard = true; transcript = ""; publish(.guardCode)
                } else if lower.contains("confirm") && (lower.contains("mobile") || lower.contains("steam app")) {
                    publish(.mobileApproval)
                } else if lower.contains("downloading item") || lower.contains("update state") {
                    publish(.downloading(Self.progress(in: transcript)))
                } else if lower.contains("logging in") { publish(.signingIn) }
            } else if !process.isRunning { break }
        }
        process.waitUntilExit()
        if lock.withLock({ cancelled }) { throw CancellationError() }
        if process.terminationStatus == 42 { throw Bootstrap.restart }
        guard process.terminationStatus == 0, success else { throw WorkshopFailure.downloadFailed }
        return staging.appendingPathComponent("steamapps/workshop/content/431960/" + id, isDirectory: true)
    }

    static func progress(in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"progress:\s*([0-9]+(?:\.[0-9]+)?)"#, options: .caseInsensitive),
              let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let range = Range(match.range(at: 1), in: text), let value = Double(text[range]) else { return nil }
        return min(1, max(0, (value * 10).rounded() / 1000))
    }
}
