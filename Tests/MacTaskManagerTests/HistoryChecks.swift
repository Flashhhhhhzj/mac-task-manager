import AppKit
import Foundation

@main
enum HistoryChecks {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacHistoryChecks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppHistoryStore(directory: directory)
        let date = Date()
        let app = process(100, cpu: 100, network: 1000)
        let child = process(101, parent: 100, cpu: 300, network: 6000)
        let otherUser = process(200, cpu: 100, network: 1000, uid: getuid() + 1000)
        store.record([app, child, otherUser], at: date)
        precondition(store.entries.count == 1 && store.entries[0].cpuNanoseconds == nil, "Initial counters must be a baseline, and other users must be excluded")
        store.record([process(100, cpu: 150, network: 1200), process(101, parent: 100, cpu: 360, network: 6400)], at: date.addingTimeInterval(2))
        precondition(store.entries[0].cpuNanoseconds == 110 && store.entries[0].networkBytes == 600, "Raw deltas must aggregate once across a real app tree")
        store.record([process(100, cpu: 150, network: 1200), process(101, parent: 100, cpu: 360, network: 6400)], at: date.addingTimeInterval(4))
        precondition(store.entries[0].cpuNanoseconds == 110 && store.entries[0].networkBytes == 600, "Repeated counters must not double-count")
        store.record([process(100, start: 2, cpu: 9000, network: 9000)], at: date.addingTimeInterval(6))
        precondition(store.entries[0].cpuNanoseconds == 110, "A reused PID must start a new baseline")
        store.record([], at: date.addingTimeInterval(8))
        precondition(store.entries.count == 1, "Exited apps must retain their history")
        store.shutdown()
        let loaded = AppHistoryStore(directory: directory)
        precondition(loaded.entries.first?.cpuNanoseconds == 110)
        loaded.record([process(100, cpu: 90_000, network: 90_000)], at: date.addingTimeInterval(10))
        precondition(loaded.entries.first?.cpuNanoseconds == 110, "Restarting must not backfill counters collected while the app was closed")
        loaded.clear(at: date.addingTimeInterval(11))
        loaded.record([process(100, cpu: 91_000, network: 91_000)], at: date.addingTimeInterval(12))
        precondition(loaded.entries.first?.cpuNanoseconds == nil, "Clearing must also reset live baselines")
        loaded.shutdown()
        let archive = directory.appendingPathComponent("history-v1.json")
        try Data("corrupt".utf8).write(to: archive)
        let corrupt = AppHistoryStore(directory: directory)
        precondition(corrupt.errorMessage != nil)
        corrupt.record([app]); corrupt.shutdown()
        let retained = try Data(contentsOf: archive)
        precondition(retained == Data("corrupt".utf8), "Corrupt history must not be overwritten")
        precondition(AppHistoryStore.delta(10, 11) == nil && AppHistoryStore.delta(nil, 10) == nil)
        print("HistoryChecks: aggregation, repeat samples, PID reuse, exit, persistence, reset, privacy and corruption passed")
    }

    private static func process(_ pid: Int32, parent: Int32 = 1, start: UInt64 = 1, cpu: UInt64, network: UInt64, uid: UInt32 = getuid()) -> AppProcess {
        var value = AppProcess(pid: pid, parentPID: parent, runningSeconds: nil, name: pid == 101 ? "Helper" : "App", cpuUsage: 0, gpuUsage: 0,
            memoryUsage: 0, diskBytesPerSecond: 0, networkBytesPerSecond: 0, user: "test", icon: nil, isApp: pid != 101, status: .none)
        value.metadata = ProcessMetadata(identity: ProcessIdentity(pid: pid, startSeconds: start, startMicroseconds: 0), uid: uid,
            executablePath: "/Applications/App.app/Contents/MacOS/App", bundlePath: pid == 101 ? nil : "/Applications/App.app",
            cpuNanoseconds: cpu, receivedBytes: network, sentBytes: 0)
        return value
    }
}
