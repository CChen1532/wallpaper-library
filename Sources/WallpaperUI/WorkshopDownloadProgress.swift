import Foundation

struct WorkshopDownloadProgress: Equatable, Sendable {
    var fraction: Double?
    var bytesPerSecond: Double?
    var receivedBytes: Int64 = 0
    var estimated = false
}

/// Network counters belong to the isolated SteamCMD process, not the whole Mac.
/// The first sample is a baseline; cached/resumed bytes never inflate speed.
struct WorkshopTransferMeter {
    private var previous: (bytes: Int64, time: TimeInterval)?
    private(set) var received: Int64 = 0
    private var speed: Double?
    private var lastSample: TimeInterval?
    mutating func observe(bytes: Int64, at time: TimeInterval) {
        guard bytes >= 0, time.isFinite else { return }
        defer { previous = (bytes, time); lastSample = time }
        guard let previous else { return }
        let elapsed = time - previous.time
        guard elapsed >= 0.2, bytes >= previous.bytes else { speed = nil; return }
        let delta = bytes - previous.bytes
        let (sum, overflow) = received.addingReportingOverflow(delta)
        if !overflow { received = sum }
        let rate = Double(delta) / elapsed
        speed = speed.map { $0 * 0.35 + rate * 0.65 } ?? rate
        if delta == 0 { speed = 0 }
    }
    func snapshot(progress: Double?, expectedBytes: Int64, at time: TimeInterval) -> WorkshopDownloadProgress {
        let known = progress.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        let estimated = known == nil && expectedBytes > 0 && received > 0
        // Metadata is uncompressed size; incoming bytes include protocol overhead.
        // This is explicitly an estimate and never signals completion.
        let fraction = known ?? (estimated ? min(0.99, Double(received) / Double(expectedBytes)) : nil)
        let currentSpeed = lastSample.map { time - $0 <= 3 } == true ? speed : nil
        return .init(fraction: fraction, bytesPerSecond: currentSpeed, receivedBytes: received, estimated: estimated)
    }
    static func networkBytes(in line: String, pid: Int32) -> Int64? {
        let columns = line.split(separator: ",", omittingEmptySubsequences: false)
        guard columns.count >= 2, columns[0].hasSuffix(".\(pid)"), let value = Int64(columns[1]), value >= 0 else { return nil }
        return value
    }
}

/// One bounded, process-filtered system sampler per active item. It starts only
/// after Steam acknowledges the item download, and is reaped on every exit.
final class WorkshopNetworkSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var meter = WorkshopTransferMeter()
    private var stopped = false
    private var active = false
    private var child: Process?
    private let finished = DispatchGroup()
    private let pid: Int32
    init(pid: Int32) { self.pid = pid }
    var isRunning: Bool { lock.withLock { active } }
    func start() {
        guard lock.withLock({ if active || stopped { return false }; active = true; return true }) else { return }
        finished.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { lock.withLock { active = false; child = nil }; finished.leave() }
            while !lock.withLock({ stopped }) {
                let began = ProcessInfo.processInfo.systemUptime
                sample()
                // nettop buffers its endless CSV pipe. A single-snapshot process
                // exits and flushes immediately; only one sample is started per second.
                while ProcessInfo.processInfo.systemUptime < began + 1, !lock.withLock({ stopped }) { usleep(50_000) }
            }
        }
    }
    private func sample() {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-n", "-P", "-L", "1", "-x", "-J", "bytes_in", "-p", String(pid)]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        guard lock.withLock({ if stopped { return false }; child = process; return true }) else { return }
        do { try process.run() } catch { lock.withLock { child = nil }; return }
        try? output.fileHandleForWriting.close()
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline && !lock.withLock({ stopped }) { usleep(10_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        try? output.fileHandleForReading.close()
        lock.withLock {
            child = nil
            guard !stopped, process.terminationStatus == 0 else { return }
            let values = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
                .compactMap { WorkshopTransferMeter.networkBytes(in: $0, pid: pid) }
            if let bytes = values.last { meter.observe(bytes: bytes, at: ProcessInfo.processInfo.systemUptime) }
        }
    }
    func snapshot(progress: Double?, expectedBytes: Int64) -> WorkshopDownloadProgress {
        lock.withLock { meter.snapshot(progress: progress, expectedBytes: expectedBytes, at: ProcessInfo.processInfo.systemUptime) }
    }
    func stop() {
        let process = lock.withLock { stopped = true; return child }
        if let process, process.isRunning { process.terminate() }
        _ = finished.wait(timeout: .now() + 2)
    }
}
