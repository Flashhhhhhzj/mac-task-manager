import AppKit

@main
enum ProcessTableChecks {
    static func main() {
        checkSortSelection()
        checkEveryColumn()
        checkTreeAndResources()
        checkFrozenOrderAndSearch()
        checkGroupingToggle()
        print("ProcessTableChecks: sort directions, grouped totals, tree order, stable ties, freeze and search passed")
    }

    private static let processes = [
        process(10, "Zulu", app: true, cpu: 1, gpu: 1, memory: 100, disk: 1, network: 1),
        process(11, "worker", parent: 10, cpu: 9, memory: 400, disk: 1, network: 12),
        process(20, "Alpha", app: true, cpu: 4, gpu: 8, memory: 300, disk: 10, network: 5),
        process(30, "z daemon", cpu: 1, gpu: 8, memory: 900, disk: 40, network: 2),
        process(40, "a daemon", cpu: 8, gpu: 1, memory: 100, disk: 5, network: 30)
    ]

    private static func checkSortSelection() {
        var sort = ProcessSort()
        precondition(sort.column == .memory && !sort.ascending && sort.arrowSymbol == "chevron.down",
                     "Initial state must select memory from high to low")
        sort.select(.memory)
        precondition(sort.ascending && sort.arrowSymbol == "chevron.up", "Clicking the default memory column must reverse it")
        sort = ProcessSort()
        for column in ProcessSortColumn.allCases {
            sort.select(column)
            precondition(sort.ascending == (column == .name) && sort.arrowSymbol == "chevron.down")
            sort.select(column)
            precondition(sort.ascending != (column == .name) && sort.arrowSymbol == "chevron.up")
        }
    }

    private static func checkEveryColumn() {
        let expected: [(ProcessSortColumn, [Int32], [Int32])] = [
            (.name, [20, 10], [40, 30]),
            (.cpu, [10, 20], [40, 30]),
            (.gpu, [20, 10], [30, 40]),
            (.memory, [10, 20], [30, 40]),
            (.disk, [20, 10], [30, 40]),
            (.network, [10, 20], [40, 30])
        ]
        for (column, apps, background) in expected {
            var sort = ProcessSort()
            if column != .memory { sort.select(column) }
            let forward = table(processes, sort: sort)
            precondition(forward.appRootProcesses.map(\.pid) == apps, column.rawValue)
            precondition(forward.backgroundRootProcesses.map(\.pid) == background, column.rawValue)
            sort.select(column)
            let reverse = table(processes, sort: sort)
            precondition(reverse.appRootProcesses.map(\.pid) == apps.reversed(), column.rawValue)
            precondition(reverse.backgroundRootProcesses.map(\.pid) == background.reversed(), column.rawValue)
        }
        precondition(table(processes).appRootProcesses.map(\.pid) == [10, 20], "Default memory ordering must use displayed group totals")
        var name = ProcessSort()
        name.select(.name)
        let ties = table([process(4, "same"), process(3, "same"), process(2, "worker10"), process(1, "worker2")], sort: name)
        precondition(ties.backgroundRootProcesses.map(\.pid) == [3, 4, 1, 2], "Natural names and PID ties must be stable")
    }

    private static func checkTreeAndResources() {
        let tree = [process(10, "App", app: true, parent: 50, memory: 10),
                    process(11, "Zulu", parent: 10, cpu: 9, memory: 11),
                    process(12, "Alpha", parent: 10, cpu: 2, memory: 12),
                    process(20, "Another app", app: true, parent: 10, memory: 20),
                    process(50, "Shell", memory: 50)]
        var sort = ProcessSort()
        sort.select(.name)
        let names = table(tree, sort: sort, expanded: [10, 50])
        precondition(Set(names.appRootProcesses.map(\.pid)) == [10, 20])
        precondition(names.appProcessRows.filter { $0.level == 1 }.map(\.id) == [12, 11])
        precondition(names.backgroundProcessRows.map(\.id) == [50])
        let roots = (names.appProcessRows + names.backgroundProcessRows).filter { $0.level == 0 }
        precondition(roots.reduce(UInt64(0)) { $0 + $1.resources.memoryUsage } == tree.reduce(0) { $0 + $1.memoryUsage })
        sort.select(.cpu)
        precondition(table(tree, sort: sort, expanded: [10]).appProcessRows.filter { $0.level == 1 }.map(\.id) == [11, 12])
    }

    private static func checkFrozenOrderAndSearch() {
        let frozen = table(processes).filteredProcesses.map(\.pid)
        let changed = processes.filter { $0.pid != 20 } + [process(20, "Alpha", app: true, memory: 10_000)]
        precondition(table(changed).appRootProcesses.map(\.pid) == [20, 10])
        let held = ProcessTableData.make(processes: changed, searchText: "", frozenProcessOrder: frozen, expandedProcessIDs: [])
        precondition(held.appRootProcesses.map(\.pid) == [10, 20])
        let search = ProcessTableData.make(processes: processes, searchText: "worker", frozenProcessOrder: nil, expandedProcessIDs: [])
        precondition(search.backgroundProcessRows.map(\.id) == [11], "Search must keep matching children when the parent is absent")
    }

    private static func checkGroupingToggle() {
        let flat = ProcessTableData.make(processes: processes, searchText: "", frozenProcessOrder: nil,
                                        expandedProcessIDs: [10], groupByType: false)
        precondition(flat.allProcessRows.filter { $0.level == 0 }.map(\.id) == [30, 10, 20, 40],
                     "Ungrouped roots must follow the selected metric across both types")
        precondition(flat.allProcessRows.map(\.id) == [30, 10, 11, 20, 40], "Expand-all must retain the parent-child order")
        precondition(Set(flat.allProcessRows.map(\.id)).count == processes.count, "Grouping must not duplicate or omit processes")
        let collapsed = ProcessTableData.make(processes: processes, searchText: "", frozenProcessOrder: nil,
                                             expandedProcessIDs: [], groupByType: false)
        precondition(collapsed.allProcessRows.count == 4, "Collapse-all must hide descendants")
    }

    private static func table(_ processes: [AppProcess], sort: ProcessSort = ProcessSort(), expanded: Set<Int32> = []) -> ProcessTableData {
        ProcessTableData.make(processes: processes, searchText: "", frozenProcessOrder: nil, expandedProcessIDs: expanded, sort: sort)
    }

    private static func process(_ pid: Int32, _ name: String, app: Bool = false, parent: Int32 = 1,
                                cpu: Double = 0, gpu: Double = 0, memory: UInt64 = 0,
                                disk: Double = 0, network: Double = 0) -> AppProcess {
        AppProcess(pid: pid, parentPID: parent, runningSeconds: nil, name: name, cpuUsage: cpu,
                   gpuUsage: gpu, memoryUsage: memory, diskBytesPerSecond: disk,
                   networkBytesPerSecond: network, user: "test", icon: nil, isApp: app, status: .none)
    }
}
