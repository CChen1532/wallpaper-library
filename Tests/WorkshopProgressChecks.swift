import Foundation

@main struct WorkshopProgressChecks {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ name: String) { precondition(value, name); count += 1; print("PASS: " + name) }
        var meter = WorkshopTransferMeter()
        check(meter.snapshot(progress: nil, expectedBytes: 1000, at: 0).fraction == nil, "no fabricated initial percentage")
        meter.observe(bytes: 9_000, at: 1)
        check(meter.snapshot(progress: nil, expectedBytes: 1000, at: 1).bytesPerSecond == nil, "first resumed sample is baseline")
        meter.observe(bytes: 9_500, at: 2)
        var value = meter.snapshot(progress: nil, expectedBytes: 1000, at: 2)
        check(value.bytesPerSecond == 500 && value.receivedBytes == 500, "speed uses monotonic byte deltas")
        check(value.estimated && value.fraction == 0.5, "metadata-derived progress is explicitly estimated")
        value = meter.snapshot(progress: 0.375, expectedBytes: 1000, at: 2)
        check(!value.estimated && value.fraction == 0.375 && value.bytesPerSecond == 500, "Steam percentage takes priority")
        meter.observe(bytes: 9_500, at: 3)
        check(meter.snapshot(progress: nil, expectedBytes: 1000, at: 3).bytesPerSecond == 0, "stalled transfer shows zero speed")
        meter.observe(bytes: 200, at: 4)
        check(meter.snapshot(progress: nil, expectedBytes: 1000, at: 4).bytesPerSecond == nil, "socket counter reset never gives negative speed")
        meter.observe(bytes: 300, at: 5)
        check(meter.snapshot(progress: nil, expectedBytes: 1000, at: 5).receivedBytes == 600, "counter reset establishes a new baseline")
        check(meter.snapshot(progress: nil, expectedBytes: 1000, at: 9).bytesPerSecond == nil, "stale speed becomes unknown")
        check(meter.snapshot(progress: nil, expectedBytes: 0, at: 5).fraction == nil, "unknown total remains indeterminate")
        check(meter.snapshot(progress: nil, expectedBytes: 10, at: 5).fraction == 0.99, "estimated progress cannot claim completion")
        check(meter.snapshot(progress: 1, expectedBytes: 10, at: 5).fraction == 1, "Steam completion can reach 100 percent")
        check(meter.snapshot(progress: .nan, expectedBytes: 1000, at: 5).estimated, "nonfinite percentage is rejected")
        check(WorkshopTransferMeter.networkBytes(in: "steamcmd.123,9000,", pid: 123) == 9000, "parse process CSV without connection details")
        for line in [",bytes_in,", "steamcmd.456,9000,", "steamcmd.123,-1,", "steamcmd.123,invalid,"] {
            check(WorkshopTransferMeter.networkBytes(in: line, pid: 123) == nil, "ignore headers, other processes and malformed counters")
        }
        let fresh = WorkshopTransferMeter().snapshot(progress: nil, expectedBytes: 1000, at: 10)
        check(fresh.bytesPerSecond == nil && fresh.receivedBytes == 0 && fresh.fraction == nil, "next queued item starts with clean telemetry")
        if CommandLine.arguments.contains("--network") {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            child.arguments = ["Tests/Fixtures/workshop-network-fixture.py"]
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            try child.run()
            let sampler = WorkshopNetworkSampler(pid: child.processIdentifier)
            defer { sampler.stop(); if child.isRunning { child.terminate(); child.waitUntilExit() } }
            sampler.start()
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            var observedSpeed = false, observedBytes = false
            while ProcessInfo.processInfo.systemUptime < deadline, child.isRunning {
                let sample = sampler.snapshot(progress: nil, expectedBytes: 5_242_880)
                if let speed = sample.bytesPerSecond, speed > 0 { observedSpeed = true }
                if sample.receivedBytes > 0 && sample.estimated { observedBytes = true }
                usleep(100_000)
            }
            check(observedSpeed && observedBytes, "real system sampler reports controlled loopback traffic")
            sampler.stop()
            check(!sampler.isRunning, "network sampler process is reaped on stop")
        }
        print("\(count) download telemetry checks passed")
    }
}
