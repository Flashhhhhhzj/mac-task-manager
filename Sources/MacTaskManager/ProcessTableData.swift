import AppKit

enum ProcessStatus {
    case none
    case efficiency
    case suspended
}

struct AppProcess: Identifiable {
    var id: Int32 { pid }
    let pid: Int32
    let parentPID: Int32
    let runningSeconds: TimeInterval?
    let name: String
    let cpuUsage: Double
    let gpuUsage: Double
    let memoryUsage: UInt64
    let diskBytesPerSecond: Double
    let networkBytesPerSecond: Double
    let user: String
    let icon: NSImage?
    let isApp: Bool
    let status: ProcessStatus
    var metadata = ProcessMetadata()
}

struct ProcessIdentity: Hashable, Codable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    var key: String { "\(pid):\(startSeconds):\(startMicroseconds)" }
    var startDate: Date { Date(timeIntervalSince1970: Double(startSeconds) + Double(startMicroseconds) / 1_000_000) }

    static func read(_ pid: Int32) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info) else { return nil }
        return ProcessIdentity(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }
}

struct ProcessMetadata {
    var identity: ProcessIdentity?
    var uid: UInt32?
    var executablePath: String?
    var bundlePath: String?
    var bundleIdentifier: String?
    var state = "未知"
    var architecture = "—"
    var cpuNanoseconds: UInt64?
    var receivedBytes: UInt64?
    var sentBytes: UInt64?
}


enum ProcessSortColumn: String, CaseIterable {
    case name = "名称"
    case cpu = "CPU"
    case gpu = "GPU"
    case memory = "内存"
    case disk = "磁盘"
    case network = "网络"

    fileprivate func value(in resources: ProcessResourceValues) -> Double {
        switch self {
        case .name: return 0
        case .cpu: return resources.cpuUsage
        case .gpu: return resources.gpuUsage
        case .memory: return Double(resources.memoryUsage)
        case .disk: return resources.diskBytesPerSecond
        case .network: return resources.networkBytesPerSecond
        }
    }
}

struct ProcessSort: Equatable {
    private(set) var column: ProcessSortColumn = .memory
    private(set) var ascending = false

    mutating func select(_ column: ProcessSortColumn) {
        ascending = self.column == column ? !ascending : column == .name
        self.column = column
    }

    var arrowSymbol: String {
        ascending == (column == .name) ? "chevron.down" : "chevron.up"
    }

    var directionLabel: String {
        column == .name ? (ascending ? "A 到 Z" : "Z 到 A") : (ascending ? "从低到高" : "从高到低")
    }
}

struct ProcessResourceValues {
    var cpuUsage: Double
    var gpuUsage: Double
    var memoryUsage: UInt64
    var diskBytesPerSecond: Double
    var networkBytesPerSecond: Double

    static func from(_ process: AppProcess) -> ProcessResourceValues {
        ProcessResourceValues(
            cpuUsage: process.cpuUsage,
            gpuUsage: process.gpuUsage,
            memoryUsage: process.memoryUsage,
            diskBytesPerSecond: process.diskBytesPerSecond,
            networkBytesPerSecond: process.networkBytesPerSecond
        )
    }

    mutating func add(_ values: ProcessResourceValues) {
        cpuUsage += values.cpuUsage
        gpuUsage += values.gpuUsage
        memoryUsage += values.memoryUsage
        diskBytesPerSecond += values.diskBytesPerSecond
        networkBytesPerSecond += values.networkBytesPerSecond
    }
}

struct ProcessTreeRow: Identifiable {
    var id: Int32 { process.pid }
    let process: AppProcess
    let resources: ProcessResourceValues
    let level: Int
    let hasChildren: Bool
    let childCount: Int
    let isExpanded: Bool
}

struct ProcessTableData {
    let filteredProcesses: [AppProcess]
    let appRootProcesses: [AppProcess]
    let backgroundRootProcesses: [AppProcess]
    let appProcessRows: [ProcessTreeRow]
    let backgroundProcessRows: [ProcessTreeRow]
    let allProcessRows: [ProcessTreeRow]

    static func make(
        processes: [AppProcess],
        searchText: String,
        frozenProcessOrder: [Int32]?,
        expandedProcessIDs: Set<Int32>,
        sort: ProcessSort = ProcessSort(),
        groupByType: Bool = true
    ) -> ProcessTableData {
        let matchingProcesses = processes.filter { process in
            searchText.isEmpty ||
                process.name.localizedCaseInsensitiveContains(searchText) ||
                process.user.localizedCaseInsensitiveContains(searchText) ||
                String(process.pid).contains(searchText)
        }
        let visiblePIDs = Set(matchingProcesses.map(\.pid))
        let isChild = { (process: AppProcess) in
            !process.isApp && process.parentPID > 1 && visiblePIDs.contains(process.parentPID)
        }
        var childrenByParent = Dictionary(grouping: matchingProcesses.filter(isChild), by: \.parentPID)
        let resourcesByPID = aggregateResourcesByPID(processes: matchingProcesses, childrenByParent: childrenByParent)
        let normallySorted = normallySortedProcesses(matchingProcesses, resourcesByPID: resourcesByPID, sort: sort, groupByType: groupByType)
        let filteredProcesses = frozenSortedProcesses(normallySorted, frozenProcessOrder: frozenProcessOrder)
        childrenByParent = Dictionary(grouping: filteredProcesses.filter(isChild), by: \.parentPID)
        // A user-facing app stays in the app section even when launched by a shell or another app.
        let rootProcesses = filteredProcesses.filter { !isChild($0) }
        let appRootProcesses = rootProcesses.filter { $0.isApp }
        let backgroundRootProcesses = rootProcesses.filter { !$0.isApp }

        return ProcessTableData(
            filteredProcesses: filteredProcesses,
            appRootProcesses: appRootProcesses,
            backgroundRootProcesses: backgroundRootProcesses,
            appProcessRows: visibleRows(
                for: appRootProcesses,
                childrenByParent: childrenByParent,
                resourcesByPID: resourcesByPID,
                expandedProcessIDs: expandedProcessIDs
            ),
            backgroundProcessRows: visibleRows(
                for: backgroundRootProcesses,
                childrenByParent: childrenByParent,
                resourcesByPID: resourcesByPID,
                expandedProcessIDs: expandedProcessIDs
            ),
            allProcessRows: groupByType ? [] : visibleRows(
                for: rootProcesses,
                childrenByParent: childrenByParent,
                resourcesByPID: resourcesByPID,
                expandedProcessIDs: expandedProcessIDs
            )
        )
    }

    private static func normallySortedProcesses(
        _ processes: [AppProcess],
        resourcesByPID: [Int32: ProcessResourceValues],
        sort: ProcessSort,
        groupByType: Bool
    ) -> [AppProcess] {
        let column = sort.column
        return processes.sorted {
            if groupByType && $0.isApp != $1.isApp { return $0.isApp && !$1.isApp }
            if column != .name {
                let left = column.value(in: resourcesByPID[$0.pid] ?? .from($0))
                let right = column.value(in: resourcesByPID[$1.pid] ?? .from($1))
                if left != right { return sort.ascending ? left < right : left > right }
            }
            let names = $0.name.localizedStandardCompare($1.name)
            if names != .orderedSame {
                return column == .name && !sort.ascending ? names == .orderedDescending : names == .orderedAscending
            }
            return $0.pid < $1.pid
        }
    }

    private static func frozenSortedProcesses(
        _ normallySorted: [AppProcess],
        frozenProcessOrder: [Int32]?
    ) -> [AppProcess] {
        guard let frozenProcessOrder else { return normallySorted }

        let frozenRank = Dictionary(uniqueKeysWithValues: frozenProcessOrder.enumerated().map { ($0.element, $0.offset) })
        let normalRank = Dictionary(uniqueKeysWithValues: normallySorted.enumerated().map { ($0.element.pid, $0.offset) })
        return normallySorted.sorted {
            let leftFrozenRank = frozenRank[$0.pid] ?? Int.max
            let rightFrozenRank = frozenRank[$1.pid] ?? Int.max
            if leftFrozenRank != rightFrozenRank {
                return leftFrozenRank < rightFrozenRank
            }
            return (normalRank[$0.pid] ?? Int.max) < (normalRank[$1.pid] ?? Int.max)
        }
    }

    private static func visibleRows(
        for roots: [AppProcess],
        childrenByParent: [Int32: [AppProcess]],
        resourcesByPID: [Int32: ProcessResourceValues],
        expandedProcessIDs: Set<Int32>
    ) -> [ProcessTreeRow] {
        var rows: [ProcessTreeRow] = []
        var visitedPIDs = Set<Int32>()
        for process in roots {
            appendVisibleRows(
                for: process,
                level: 0,
                childrenByParent: childrenByParent,
                resourcesByPID: resourcesByPID,
                expandedProcessIDs: expandedProcessIDs,
                visitedPIDs: &visitedPIDs,
                rows: &rows
            )
        }
        return rows
    }

    private static func appendVisibleRows(
        for process: AppProcess,
        level: Int,
        childrenByParent: [Int32: [AppProcess]],
        resourcesByPID: [Int32: ProcessResourceValues],
        expandedProcessIDs: Set<Int32>,
        visitedPIDs: inout Set<Int32>,
        rows: inout [ProcessTreeRow]
    ) {
        guard !visitedPIDs.contains(process.pid) else { return }
        visitedPIDs.insert(process.pid)

        let children = childrenByParent[process.pid] ?? []
        let isExpanded = expandedProcessIDs.contains(process.pid)
        rows.append(ProcessTreeRow(
            process: process,
            resources: resourcesByPID[process.pid] ?? .from(process),
            level: level,
            hasChildren: !children.isEmpty,
            childCount: children.count,
            isExpanded: isExpanded
        ))

        guard isExpanded else { return }
        for child in children {
            appendVisibleRows(
                for: child,
                level: level + 1,
                childrenByParent: childrenByParent,
                resourcesByPID: resourcesByPID,
                expandedProcessIDs: expandedProcessIDs,
                visitedPIDs: &visitedPIDs,
                rows: &rows
            )
        }
    }

    private static func aggregateResourcesByPID(
        processes: [AppProcess],
        childrenByParent: [Int32: [AppProcess]]
    ) -> [Int32: ProcessResourceValues] {
        let processesByPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        var memo: [Int32: ProcessResourceValues] = [:]
        var visiting = Set<Int32>()

        for process in processes {
            _ = aggregateResources(
                for: process.pid,
                processesByPID: processesByPID,
                childrenByParent: childrenByParent,
                visiting: &visiting,
                memo: &memo
            )
        }
        return memo
    }

    private static func aggregateResources(
        for pid: Int32,
        processesByPID: [Int32: AppProcess],
        childrenByParent: [Int32: [AppProcess]],
        visiting: inout Set<Int32>,
        memo: inout [Int32: ProcessResourceValues]
    ) -> ProcessResourceValues {
        if let cached = memo[pid] {
            return cached
        }
        guard let process = processesByPID[pid] else {
            return ProcessResourceValues(cpuUsage: 0, gpuUsage: 0, memoryUsage: 0, diskBytesPerSecond: 0, networkBytesPerSecond: 0)
        }
        guard !visiting.contains(pid) else {
            return .from(process)
        }

        visiting.insert(pid)
        var total = ProcessResourceValues.from(process)
        for child in childrenByParent[pid] ?? [] {
            total.add(aggregateResources(
                for: child.pid,
                processesByPID: processesByPID,
                childrenByParent: childrenByParent,
                visiting: &visiting,
                memo: &memo
            ))
        }
        visiting.remove(pid)
        memo[pid] = total
        return total
    }
}

struct ProcessTableCacheKey: Equatable {
    let processVersion: Int
    let searchText: String
    let sort: ProcessSort
    let groupByType: Bool
    let frozenProcessOrder: [Int32]?
    let expandedProcessIDs: [Int32]
}
