import AppKit
import Foundation
import Combine

struct AppHistoryEntry: Codable, Identifiable {
    let id: String
    var name: String
    var path: String?
    var cpuNanoseconds: UInt64?
    var networkBytes: UInt64?
    var lastSeen: Date
}

private struct HistoryArchive: Codable {
    let version: Int
    let startedAt: Date
    let entries: [AppHistoryEntry]
}

final class AppHistoryStore: ObservableObject {
    @Published private(set) var entries: [AppHistoryEntry] = []
    @Published private(set) var startedAt = Date()
    @Published private(set) var errorMessage: String?
    private var totals: [String: AppHistoryEntry] = [:]
    private struct Counter { let cpu: UInt64?; let received: UInt64?; let sent: UInt64? }
    private var previous: [ProcessIdentity: Counter] = [:]
    private let queue = DispatchQueue(label: "Mac-TaskManager.history-storage", qos: .utility)
    private let url: URL
    private var lastSave = Date.distantPast
    private var mayWrite = true

    init(directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mac-TaskManager/History", isDirectory: true)
        url = root.appendingPathComponent("history-v1.json")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: url.path) {
                let archive = try JSONDecoder().decode(HistoryArchive.self, from: Data(contentsOf: url))
                guard archive.version == 1 else { throw CocoaError(.coderReadCorrupt) }
                guard Set(archive.entries.map(\.id)).count == archive.entries.count else { throw CocoaError(.coderReadCorrupt) }
                startedAt = archive.startedAt
                totals = Dictionary(uniqueKeysWithValues: archive.entries.map { ($0.id, $0) })
                entries = archive.entries
            }
        } catch {
            mayWrite = false
            errorMessage = "无法读取使用历史，原文件已保留。可清除历史后重新开始。\n\(error.localizedDescription)"
        }
    }

    func record(_ processes: [AppProcess], at date: Date = Date()) {
        let map = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var current: [ProcessIdentity: Counter] = [:]
        for process in processes {
            guard let uid = process.metadata.uid, uid == getuid() || (uid < 500 && uid != 201),
                  let identity = process.metadata.identity else { continue }
            let metadata = process.metadata
            current[identity] = Counter(cpu: metadata.cpuNanoseconds, received: metadata.receivedBytes, sent: metadata.sentBytes)
            var owner = process
            var visited: Set<Int32> = [process.pid]
            while !owner.isApp, owner.parentPID > 1, !visited.contains(owner.parentPID), let parent = map[owner.parentPID],
                  parent.metadata.uid == uid {
                visited.insert(parent.pid)
                owner = parent
            }
            // Only a real application root owns a process group; unrelated daemons remain separate.
            if !owner.isApp { owner = process }
            let keyPath = owner.metadata.bundlePath ?? owner.metadata.executablePath
            guard let keyPath else { continue }
            let key = "\(uid):\(owner.isApp ? "app" : "process"):\(keyPath)"
            var entry = totals[key] ?? AppHistoryEntry(id: key, name: owner.name, path: keyPath, cpuNanoseconds: nil, networkBytes: nil, lastSeen: date)
            entry.name = owner.name
            entry.lastSeen = date
            if let old = previous[identity] {
                if let delta = Self.delta(metadata.cpuNanoseconds, old.cpu) { entry.cpuNanoseconds = (entry.cpuNanoseconds ?? 0) &+ delta }
                if let received = Self.delta(metadata.receivedBytes, old.received), let sent = Self.delta(metadata.sentBytes, old.sent) {
                    entry.networkBytes = (entry.networkBytes ?? 0) &+ received &+ sent
                }
            }
            totals[key] = entry
        }
        previous = current
        entries = Array(totals.values)
        if date.timeIntervalSince(lastSave) >= 10 { lastSave = date; save() }
    }

    static func delta(_ current: UInt64?, _ old: UInt64?) -> UInt64? {
        guard let current, let old, current >= old else { return nil }
        return current - old
    }

    func clear(at date: Date = Date()) {
        queue.sync {}
        totals.removeAll(); previous.removeAll(); entries = []; startedAt = date
        mayWrite = true; errorMessage = nil
        save()
    }

    private func save() {
        guard mayWrite else { return }
        let archive = HistoryArchive(version: 1, startedAt: startedAt, entries: entries)
        let url = self.url
        queue.async {
            do {
                try JSONEncoder().encode(archive).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                DispatchQueue.main.async { self.errorMessage = "无法保存使用历史：\(error.localizedDescription)" }
            }
        }
    }

    func shutdown() { save(); queue.sync {} }
}
