import SwiftUI
import AppKit
import Carbon
import MacManagement

struct ManagementCommandBar<Actions: View>: View {
    let title: String
    let runTask: () -> Void
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        HStack(spacing: 0) {
            Text(title).font(.system(size: TaskManagerStyle.pageTitleFontSize, weight: .semibold)).foregroundColor(TaskManagerStyle.text).padding(.leading, 20)
            Spacer(minLength: 8)
            ManagementCommandButton(icon: "macwindow.badge.plus", title: "运行新任务", action: runTask)
            actions()
        }
        .padding(.trailing, 8)
        .frame(height: TaskManagerStyle.pageToolbarHeight)
        .background(TaskManagerStyle.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(TaskManagerStyle.grid).frame(height: 1) }
    }
}

private struct ManagementCommandButton: View {
    let icon: String
    let title: String
    var enabled = true
    let action: () -> Void
    var body: some View {
        CommandButton(icon: icon, title: title, enabled: enabled, action: action)
            .accessibilityLabel(title)
            .help(enabled ? title : "请先选择可操作的项目，或等待当前操作完成；系统保护项目只读。")
    }
}

struct ManagementPage: View {
    let page: TaskManagerPage
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var state: ContentViewState
    @ObservedObject var workspace: ManagementWorkspace
    @ObservedObject private var tableState: ManagementTableState
    @ObservedObject private var history: AppHistoryStore

    init(page: TaskManagerPage, monitor: SystemMonitor, state: ContentViewState, workspace: ManagementWorkspace) {
        self.page = page; self.monitor = monitor; self.state = state; self.workspace = workspace
        self.tableState = workspace.states[page]!
        self.history = monitor.appHistory
    }

    var body: some View {
        let visibleRows = rows
        return VStack(spacing: 0) {
            commandBar
            if page == .startup {
                HStack { Spacer(); Text("上次固件启动耗时：不适用").font(.system(size: TaskManagerStyle.tableHeaderFontSize)).foregroundColor(TaskManagerStyle.text) }
                    .padding(.horizontal, 20).frame(height: 54)
            } else if page == .history {
                VStack(alignment: .leading, spacing: 3) {
                    Text("自 \(history.startedAt.formatted(date: .numeric, time: .omitted)) 以来，当前用户和系统账户在软件运行期间的资源使用情况。")
                        .foregroundColor(TaskManagerStyle.text)
                    Button("删除使用情况历史记录", action: clearHistory).buttonStyle(.plain).foregroundColor(TaskManagerStyle.accent)
                }.font(.system(size: TaskManagerStyle.tableHeaderFontSize)).padding(.horizontal, 18).frame(maxWidth: .infinity, alignment: .leading).frame(height: 64)
                if let error = history.errorMessage { errorBanner(error, dismissible: false) }
            }
            if [.startup, .services].contains(page), !workspace.authorized {
                HStack(spacing: 8) {
                    Text("当前显示可直接读取的数据；完整后台项目与系统管理需首次管理员批准。")
                    Button("启用系统管理", action: workspace.enableSystemManagement).buttonStyle(.plain).foregroundColor(TaskManagerStyle.accent)
                    Spacer()
                }.font(.system(size: TaskManagerStyle.tableHeaderFontSize)).foregroundColor(TaskManagerStyle.muted).padding(.horizontal, 18).padding(.vertical, 6)
            }
            if let message = workspace.message { errorBanner(message) }
            ManagementNativeTable(columns: columns, rows: visibleRows, state: tableState,
                                  onDoubleClick: doubleClick, onToggle: toggleUser, menu: contextMenu)
                .overlay {
                    if visibleRows.isEmpty {
                        VStack(spacing: 10) {
                            if workspace.isLoading { ProgressView().controlSize(.small) }
                            Text(workspace.isLoading ? "正在读取系统数据…" : state.searchText.isEmpty ? "暂无可显示的项目" : "没有匹配的项目")
                                .font(.system(size: TaskManagerStyle.tableBodyFontSize)).foregroundColor(TaskManagerStyle.muted)
                        }.allowsHitTesting(false)
                    }
                }
        }
        .background(TaskManagerStyle.surface)
        .onAppear { workspace.activate(page) }
        .onDisappear { workspace.deactivate(page) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in workspace.refresh(page: page, force: true) }
        .sheet(item: $workspace.properties) { ManagementPropertiesView(properties: $0) }
    }

    private var available: Bool { !workspace.isWorking && !workspace.isLoading }
    private var selectedStartup: StartupItem? { workspace.startup.first { $0.id == tableState.selectedID } }
    private var selectedService: ServiceRecord? { workspace.services.first { $0.id == tableState.selectedID } }
    private var selectedProcess: AppProcess? { monitor.processes.first { Self.processID($0) == tableState.selectedID } }
    private var canChangeStartup: Bool {
        guard let item = selectedStartup else { return false }
        return item.requiresSettings || item.legacyURL != nil || workspace.services.first(where: { $0.identifier == item.service })?.manageable == true
    }
    private var selectedUser: ManagedUser? { workspace.users(from: monitor.processes).first { $0.id == tableState.selectedID } }
    private var search: String { state.searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var columns: [ManagementColumn] {
        switch page {
        case .startup:
            return [.init(id: "name", title: "名称", width: TaskManagerStyle.tableNameWidth), .init(id: "publisher", title: "发布者", width: 200),
                    .init(id: "status", title: "状态", width: 130, numeric: true), .init(id: "impact", title: "启动影响", width: 130, sortable: false)]
        case .history:
            return [.init(id: "name", title: "名称", width: TaskManagerStyle.tableNameWidth), .init(id: "cpu", title: "CPU 时间", width: 140, numeric: true),
                    .init(id: "network", title: "网络", width: 140, numeric: true), .init(id: "notifications", title: "通知", width: 140, numeric: true, sortable: false)]
        case .users:
            return [.init(id: "name", title: "用户", width: TaskManagerStyle.tableNameWidth), .init(id: "status", title: "状态", width: 150),
                    .init(id: "cpu", title: "CPU", width: TaskManagerStyle.tableMetricWidth, numeric: true, summary: String(format: "%.0f%%", monitor.totalCPU)),
                    .init(id: "memory", title: "内存", width: TaskManagerStyle.tableMetricWidth, numeric: true, summary: monitor.totalMemory == 0 ? "—" : String(format: "%.0f%%", Double(monitor.usedMemory) / Double(monitor.totalMemory) * 100)),
                    .init(id: "disk", title: "磁盘", width: 130, numeric: true, summary: String(format: "%.1f MB/s", monitor.totalDiskBytesPerSecond / 1_048_576)),
                    .init(id: "network", title: "网络", width: 130, numeric: true, summary: String(format: "%.1f Mbps", monitor.totalNetworkBytesPerSecond * 8 / 1_000_000))]
        case .details:
            return [.init(id: "name", title: "名称", width: TaskManagerStyle.tableNameWidth), .init(id: "pid", title: "PID", width: 80, numeric: true),
                    .init(id: "status", title: "状态", width: 132), .init(id: "user", title: "用户名", width: 110),
                    .init(id: "cpu", title: "CPU", width: 64, numeric: true), .init(id: "memory", title: "内存（驻留集）", width: 150, numeric: true),
                    .init(id: "arch", title: "体系结构", width: 100), .init(id: "description", title: "描述", width: 500)]
        case .services:
            return [.init(id: "name", title: "名称", width: TaskManagerStyle.tableNameWidth), .init(id: "pid", title: "PID", width: 80, numeric: true),
                    .init(id: "description", title: "描述", width: 700)]
        default: return []
        }
    }

    private var rows: [ManagementRow] {
        let unsorted: [ManagementRow]
        switch page {
        case .startup:
            unsorted = workspace.startup.filter { matches([$0.name, $0.publisher, $0.id, $0.path ?? ""]) }.map { item in
                ManagementRow(id: item.id, cells: ["name": .init(text: item.name, icon: ManagementIcons.file(item.path)),
                    "publisher": .init(text: item.publisher), "status": .init(text: item.state, number: item.enabled.map { $0 ? 1 : 0 }, tooltip: item.protectionReason),
                    "impact": .init(text: item.impact, tooltip: "macOS 未提供此项目的可靠启动耗时计量。")])
            }
        case .history:
            let cpuMax = max(1, history.entries.compactMap(\.cpuNanoseconds).max() ?? 1)
            let networkMax = max(1, history.entries.compactMap(\.networkBytes).max() ?? 1)
            unsorted = history.entries.filter { matches([$0.name, $0.path ?? ""]) }.map { entry in
                ManagementRow(id: entry.id, cells: ["name": .init(text: entry.name, icon: ManagementIcons.file(entry.path)),
                    "cpu": .init(text: entry.cpuNanoseconds.map(ManagementFormatting.duration) ?? "—", number: entry.cpuNanoseconds.map(Double.init), heat: entry.cpuNanoseconds.map { Double($0) / Double(cpuMax) } ?? 0),
                    "network": .init(text: entry.networkBytes.map(ManagementFormatting.bytes) ?? "—", number: entry.networkBytes.map(Double.init), heat: entry.networkBytes.map { Double($0) / Double(networkMax) } ?? 0, tooltip: entry.networkBytes == nil ? "尚未获得可用的网络累计计数；不会将读取失败记为零。" : nil),
                    "notifications": .init(text: "—", muted: true, tooltip: "macOS 没有对应的其他应用通知资源计量接口。")])
            }
        case .users: return userRows
        case .details:
            unsorted = monitor.processes.filter { matches([$0.name, String($0.pid), $0.user, $0.metadata.executablePath ?? ""]) }.map { process in
                ManagementRow(id: Self.processID(process), cells: [
                    "name": .init(text: process.metadata.executablePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? process.name, icon: process.icon),
                    "pid": .init(text: String(process.pid), number: Double(process.pid)), "status": .init(text: process.metadata.state),
                    "user": .init(text: process.user), "cpu": .init(text: String(format: "%02.0f", process.cpuUsage), number: process.cpuUsage),
                    "memory": .init(text: ManagementFormatting.memory(process.memoryUsage), number: Double(process.memoryUsage)),
                    "arch": .init(text: process.metadata.architecture), "description": .init(text: process.name)])
            }
        case .services:
            unsorted = workspace.services.filter { matches([$0.name, $0.summary, $0.identifier.key, $0.pid.map(String.init) ?? ""]) }.map { service in
                ManagementRow(id: service.id, cells: ["name": .init(text: service.name, icon: ManagementIcons.gear, tooltip: "\(service.identifier.key)\n\(service.state)\n\(service.protectionReason ?? "")"),
                    "pid": .init(text: service.pid.map(String.init) ?? "", number: service.pid.map(Double.init)),
                    "description": .init(text: service.summary, tooltip: "\(service.summary)\n状态：\(service.state)")])
            }
        default: unsorted = []
        }
        return ManagementFormatting.sorted(unsorted, state: tableState, columns: columns)
    }

    private var userRows: [ManagementRow] {
        let users = workspace.users(from: monitor.processes)
        var roots: [ManagementRow] = []
        var children: [String: [ManagementRow]] = [:]
        for user in users {
            let userMatch = matches([user.name, user.account, String(user.uid)])
            let processes = user.processes.filter { userMatch || matches([$0.name, String($0.pid)]) }
            guard search.isEmpty || userMatch || !processes.isEmpty else { continue }
            var resources = ProcessResourceValues(cpuUsage: 0, gpuUsage: 0, memoryUsage: 0, diskBytesPerSecond: 0, networkBytesPerSecond: 0)
            for process in user.processes { resources.add(.from(process)) }
            var cells = resourceCells(resources)
            cells["name"] = .init(text: "\(user.name) (\(user.processes.count))", icon: ManagementIcons.person, tooltip: "\(user.account) · UID \(user.uid)")
            cells["status"] = .init(text: user.state)
            roots.append(ManagementRow(id: user.id, cells: cells, expandable: !user.processes.isEmpty, expanded: tableState.expandedUsers.contains(user.uid) || !search.isEmpty))
            children[user.id] = processes.map { process in
                var cells = resourceCells(.from(process))
                cells["name"] = .init(text: process.name, icon: process.icon, tooltip: "\(process.name) · PID \(process.pid)")
                cells["status"] = .init(text: process.metadata.state == "已停止" ? "已停止" : "")
                return ManagementRow(id: Self.processID(process), cells: cells, level: 1)
            }
        }
        return ManagementFormatting.sorted(roots, state: tableState, columns: columns).flatMap { root in
            [root] + (root.expanded ? ManagementFormatting.sorted(children[root.id] ?? [], state: tableState, columns: columns) : [])
        }
    }

    private func resourceCells(_ resources: ProcessResourceValues) -> [String: ManagementCell] {
        ["cpu": .init(text: ManagementFormatting.cpu(resources.cpuUsage), number: resources.cpuUsage, heat: min(resources.cpuUsage / 12, 1)),
         "memory": .init(text: ManagementFormatting.memory(resources.memoryUsage), number: Double(resources.memoryUsage), heat: min(Double(resources.memoryUsage) / 1_048_576 / 900, 1)),
         "disk": .init(text: ManagementFormatting.disk(resources.diskBytesPerSecond), number: resources.diskBytesPerSecond, heat: min(resources.diskBytesPerSecond / 1_048_576 / 10, 1)),
         "network": .init(text: ManagementFormatting.network(resources.networkBytesPerSecond), number: resources.networkBytesPerSecond, heat: min(resources.networkBytesPerSecond / 1_048_576, 1))]
    }

    private var commandBar: some View {
        ManagementCommandBar(title: page.rawValue, runTask: { state.showRunTaskDialog = true }) {
            if page == .startup {
                CommandSeparator()
                ManagementCommandButton(icon: "checkmark", title: "启用", enabled: available && canChangeStartup && selectedStartup?.enabled == false) { if let selectedStartup { workspace.setStartup(selectedStartup, enabled: true) } }
                ManagementCommandButton(icon: "nosign", title: "禁用", enabled: available && canChangeStartup && selectedStartup?.enabled == true) { if let selectedStartup { workspace.setStartup(selectedStartup, enabled: false) } }
                ManagementCommandButton(icon: "doc.text", title: "属性", enabled: selectedStartup != nil) { if let selectedStartup { workspace.showProperties(selectedStartup) } }
            } else if page == .users {
                CommandSeparator()
                ManagementCommandButton(icon: "person.crop.circle.badge.xmark", title: "注销当前用户", enabled: selectedUser?.uid == getuid(), action: logout)
                ManagementCommandButton(icon: "person.2", title: "管理用户账户", action: openUsersSettings)
            } else if page == .details {
                CommandSeparator()
                ManagementCommandButton(icon: "nosign", title: "结束任务", enabled: selectedProcess.map(canTerminate) == true) { if let selectedProcess { terminate(selectedProcess) } }
            } else if page == .services {
                CommandSeparator()
                ManagementCommandButton(icon: "play", title: "启动", enabled: available && selectedService?.manageable == true && selectedService?.loaded == false && selectedService?.enabled == true) { serviceAction(.start) }
                ManagementCommandButton(icon: "stop", title: "停止", enabled: available && selectedService?.manageable == true && selectedService?.loaded == true) { serviceAction(.stop) }
                ManagementCommandButton(icon: "arrow.clockwise", title: "重启", enabled: available && selectedService?.manageable == true && selectedService?.loaded == true && selectedService?.enabled == true) { serviceAction(.restart) }
                CommandSeparator()
                ManagementCommandButton(icon: "gearshape", title: "打开服务", enabled: selectedService != nil) { if let selectedService { workspace.showProperties(selectedService) } }
            }
            if workspace.isWorking || workspace.isLoading { ProgressView().controlSize(.small).frame(width: 22) }
            TaskManagerOverflowMenuButton(makeMenu: makeOverflowMenu).frame(width: 48, height: 40)
        }
    }

    private func makeOverflowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.font = .systemFont(ofSize: TaskManagerStyle.tableHeaderFontSize)
        menu.minimumWidth = 190
        let viewMenu = NSMenu(title: "视图")
        viewMenu.autoenablesItems = false
        viewMenu.font = menu.font
        viewMenu.minimumWidth = 170
        if page == .users {
            viewMenu.addItem(TaskManagerMenuItem("全部展开") { tableState.expandedUsers = Set(workspace.users(from: monitor.processes).map(\.uid)) })
            viewMenu.addItem(TaskManagerMenuItem("全部折叠") { tableState.expandedUsers = [] })
        }
        viewMenu.addItem(TaskManagerMenuItem("刷新", action: refresh))
        let view = NSMenuItem(title: "视图", action: nil, keyEquivalent: "")
        view.submenu = viewMenu
        menu.addItem(view)
        if [.startup, .services].contains(page) {
            menu.addItem(TaskManagerMenuItem("打开登录项设置", action: FanHelperRegistration.openSystemSettings))
        }
        menu.addItem(TaskManagerMenuItem("复制选中行", enabled: tableState.selectedID != nil, action: copySelection))
        return menu
    }

    private func matches(_ values: [String]) -> Bool { search.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(search) } }
    static func processID(_ process: AppProcess) -> String { "process:\(process.metadata.identity?.key ?? String(process.pid))" }
    private func toggleUser(_ id: String) {
        guard id.hasPrefix("user:"), let uid = UInt32(id.dropFirst(5)) else { return }
        if tableState.expandedUsers.contains(uid) { tableState.expandedUsers.remove(uid) } else { tableState.expandedUsers.insert(uid) }
    }
    private func serviceAction(_ operation: ServiceOperation) { if let selectedService { workspace.operate(operation, service: selectedService) } }
    private func refresh() {
        if [.details, .history, .users].contains(page) { monitor.updateData() }
        workspace.refresh(page: page, force: true)
    }
    private func clearHistory() {
        let alert = NSAlert(); alert.messageText = "删除使用情况历史记录？"; alert.informativeText = "所有累计值将清除，并从现在重新统计。"
        alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { history.clear() }
    }
    private func doubleClick(_ id: String) {
        if page == .startup, let item = workspace.startup.first(where: { $0.id == id }) { workspace.showProperties(item) }
        else if page == .services, let service = workspace.services.first(where: { $0.id == id }) { workspace.showProperties(service) }
        else if let process = monitor.processes.first(where: { Self.processID($0) == id }) {
            if page == .users { goToDetails(process) } else { workspace.showProperties(process) }
        } else if page == .users { toggleUser(id) }
        else if page == .history, let entry = history.entries.first(where: { $0.id == id }) {
            workspace.properties = ManagementProperties(title: entry.name, fields: [("名称", entry.name), ("路径", entry.path ?? "—"),
                ("CPU 时间", entry.cpuNanoseconds.map(ManagementFormatting.duration) ?? "—"), ("网络", entry.networkBytes.map(ManagementFormatting.bytes) ?? "—"),
                ("最后采样", entry.lastSeen.formatted(date: .numeric, time: .standard))], path: entry.path)
        }
    }
    private func contextMenu(_ id: String) -> [ManagementMenuAction] {
        if page == .startup, let item = workspace.startup.first(where: { $0.id == id }) {
            return [.init(title: item.enabled == true ? "禁用" : "启用", icon: "checkmark", enabled: available && ((item.enabled != nil && item.protectionReason == nil) || item.requiresSettings), action: { workspace.setStartup(item, enabled: item.enabled != true) }),
                    .init(title: "属性", icon: "doc.text", action: { workspace.showProperties(item) }),
                    .init(title: "打开文件位置", icon: "folder", enabled: item.path != nil, action: { reveal(item.path) })]
        }
        if page == .services, let service = workspace.services.first(where: { $0.id == id }) {
            return [.init(title: "启动", icon: "play", enabled: available && service.manageable && service.loaded == false && service.enabled == true, action: { workspace.operate(.start, service: service) }),
                    .init(title: "停止", icon: "stop", enabled: available && service.manageable && service.loaded == true, action: { workspace.operate(.stop, service: service) }),
                    .init(title: "重启", icon: "arrow.clockwise", enabled: available && service.manageable && service.loaded == true && service.enabled == true, action: { workspace.operate(.restart, service: service) }),
                    .init(title: "属性", icon: "doc.text", action: { workspace.showProperties(service) }),
                    .init(title: "打开配置文件位置", icon: "folder", enabled: service.plistPath != nil, action: { reveal(service.plistPath) })]
        }
        if let process = monitor.processes.first(where: { Self.processID($0) == id }) {
            var actions: [ManagementMenuAction] = [
                .init(title: "结束任务", icon: "nosign", enabled: canTerminate(process), action: { terminate(process) }),
                .init(title: "属性", icon: "doc.text", action: { workspace.showProperties(process) }),
                .init(title: "打开文件位置", icon: "folder", enabled: process.metadata.executablePath != nil, action: { reveal(process.metadata.executablePath) })]
            if page == .users { actions.insert(.init(title: "转到详细信息", action: { goToDetails(process) }), at: 0) }
            if let service = workspace.services.first(where: { $0.pid == process.pid }) {
                actions.append(.init(title: "转到服务", action: {
                    state.selectedPage = .services; state.searchText = service.identifier.label
                    workspace.states[.services]?.selectedID = service.id
                }))
            }
            return actions
        }
        if page == .users, let user = workspace.users(from: monitor.processes).first(where: { $0.id == id }) {
            return [.init(title: tableState.expandedUsers.contains(user.uid) ? "折叠" : "展开", action: { toggleUser(id) }),
                    .init(title: "注销当前用户", enabled: user.uid == getuid(), action: logout), .init(title: "管理用户账户", action: openUsersSettings)]
        }
        return [.init(title: "属性", action: { doubleClick(id) })]
    }
    private func goToDetails(_ process: AppProcess) {
        state.selectedPage = .details; state.searchText = String(process.pid)
        workspace.states[.details]?.scrollOrigin = nil
        workspace.states[.details]?.selectedID = Self.processID(process)
    }
    private func canTerminate(_ process: AppProcess) -> Bool {
        process.pid > 1 && process.metadata.identity != nil && process.metadata.uid == getuid()
            && process.metadata.executablePath?.hasPrefix("/System/") != true
    }
    private func terminate(_ process: AppProcess) {
        guard canTerminate(process), let identity = process.metadata.identity, ProcessIdentity.read(process.pid) == identity else {
            workspace.message = "进程已退出、身份已变化，或当前账户无权结束该进程。"; return
        }
        let alert = NSAlert(); alert.messageText = "\(state.terminationMode.rawValue) \(process.name)？"
        alert.informativeText = "PID \(process.pid)\n\(state.terminationMode.confirmationDescription)"
        alert.addButton(withTitle: state.terminationMode.rawValue); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            guard ProcessIdentity.read(process.pid) == identity else { workspace.message = "进程身份已变化，操作已取消。"; return }
            if !monitor.killProcess(pid: process.pid, mode: state.terminationMode) {
                workspace.message = "无法结束进程：\(String(cString: strerror(errno)))"
            }
        }
    }
    private func logout() {
        guard selectedUser?.uid == getuid() else { return }
        do {
            let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAELogOut),
                targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.loginwindow"),
                returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            _ = try event.sendEvent(options: .noReply, timeout: 30)
        } catch { workspace.message = "无法打开系统注销确认：\(error.localizedDescription)" }
    }
    private func openUsersSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension") { NSWorkspace.shared.open(url) }
    }
    private func reveal(_ path: String?) { if let path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
    private func copySelection() {
        guard let row = rows.first(where: { $0.id == tableState.selectedID }) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(columns.map { row.cells[$0.id]?.text ?? "" }.joined(separator: "\t"), forType: .string)
    }
    private func errorBanner(_ message: String, dismissible: Bool = true) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundColor(.orange)
            Text(message).font(.system(size: TaskManagerStyle.tableHeaderFontSize)).foregroundColor(TaskManagerStyle.text).textSelection(.enabled)
            Spacer()
            if dismissible {
                Button { workspace.message = nil } label: { Image(systemName: "xmark").font(.system(size: 11)) }.buttonStyle(.plain).accessibilityLabel("关闭提示")
            }
        }.padding(.horizontal, 18).padding(.vertical, 7).background(TaskManagerStyle.headerCell)
    }
}

private enum ManagementIcons {
    static let gear = NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: nil)
    static let person = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)
    private static var cache: [String: NSImage] = [:]
    static func file(_ path: String?) -> NSImage? {
        guard let path else { return nil }
        if let icon = cache[path] { return icon }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }
}

private struct ManagementPropertiesView: View {
    let properties: ManagementProperties
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(properties.title).font(.system(size: TaskManagerStyle.pageTitleFontSize, weight: .semibold)).lineLimit(2)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(properties.fields.enumerated()), id: \.offset) { _, field in
                        HStack(alignment: .top, spacing: 12) {
                            Text(field.0).foregroundColor(TaskManagerStyle.muted).frame(width: 110, alignment: .leading)
                            Text(field.1).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                    }
                }.font(.system(size: TaskManagerStyle.tableBodyFontSize)).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if let path = properties.path { Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
                if properties.opensLoginSettings { Button("登录项设置", action: FanHelperRegistration.openSystemSettings) }
                Spacer()
                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(properties.fields.map { "\($0.0)：\($0.1)" }.joined(separator: "\n"), forType: .string)
                }
                Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
            }.font(.system(size: TaskManagerStyle.tableHeaderFontSize)).controlSize(.large)
        }.padding(22).frame(width: 650, height: 480).foregroundColor(TaskManagerStyle.text).background(TaskManagerStyle.surface)
    }
}
