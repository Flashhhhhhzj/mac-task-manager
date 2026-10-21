import AppKit
import Combine
import SystemConfiguration
import MacManagement

final class ManagementTableState: ObservableObject {
    @Published var selectedID: String?
    @Published var sortColumn: String
    @Published var ascending: Bool
    @Published var expandedUsers: Set<UInt32> = [getuid()]
    var columnWidths: [String: CGFloat] = [:]
    var scrollOrigin: NSPoint?
    init(column: String, ascending: Bool) { sortColumn = column; self.ascending = ascending }
    func sort(_ column: String, numeric: Bool) {
        ascending = sortColumn == column ? !ascending : !numeric
        sortColumn = column
    }
}

struct ManagementProperties: Identifiable {
    let id = UUID()
    let title: String
    let fields: [(String, String)]
    let path: String?
    var opensLoginSettings = false
}

struct ManagedUser {
    let uid: UInt32
    let name: String
    let account: String
    let state: String
    let processes: [AppProcess]
    var id: String { "user:\(uid)" }
}

enum SystemManagementAuthorization {
    static var bundledURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/MacSystemHelper") }
    static var isEnabled: Bool { (try? SystemHelperInstallation.isCurrent(bundledURL: bundledURL)) == true }

    static func install(includeFan: Bool = false) throws {
        guard FileManager.default.isExecutableFile(atPath: bundledURL.path) else { throw ManagementFailure("请从完整的应用包中启用系统管理。") }
        let fan = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/MacFanHelper")
        let script = """
        on run argv
            set systemHelper to item 1 of argv
            set userID to item 2 of argv
            set fanHelper to item 3 of argv
            set installFan to item 4 of argv
            set taskCommand to quoted form of systemHelper & " install " & quoted form of userID
            if installFan is "yes" then set taskCommand to (quoted form of fanHelper & " install " & quoted form of userID & " && " & taskCommand)
            do shell script taskCommand with administrator privileges
        end run
        """
        _ = try ManagementCommand.run("/usr/bin/osascript", ["-e", script, "--", bundledURL.path, String(getuid()), fan.path, includeFan ? "yes" : "no"], timeout: 180)
        guard isEnabled else { throw ManagementFailure("系统管理助手安装后校验失败。") }
        _ = try SystemManagementXPC.snapshot()
    }

    static func uninstall() throws {
        let script = """
        on run argv
            do shell script (quoted form of (item 1 of argv) & " uninstall") with administrator privileges
        end run
        """
        _ = try ManagementCommand.run("/usr/bin/osascript", ["-e", script, "--", bundledURL.path], timeout: 180)
    }
}

final class ManagementWorkspace: ObservableObject {
    let states: [TaskManagerPage: ManagementTableState] = [
        .startup: .init(column: "status", ascending: false), .history: .init(column: "cpu", ascending: false),
        .users: .init(column: "name", ascending: true), .details: .init(column: "name", ascending: false),
        .services: .init(column: "name", ascending: true)
    ]
    @Published private(set) var services: [ServiceRecord] = []
    @Published private(set) var startup: [StartupItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    @Published private(set) var authorized = false
    @Published var message: String?
    @Published var properties: ManagementProperties?
    @Published private(set) var consoleUID: UInt32?
    @Published private(set) var sessionAccounts: Set<String> = []
    private let queue = DispatchQueue(label: "Mac-TaskManager.management", qos: .utility)
    private var activePage: TaskManagerPage?
    private var timer: Timer?
    private var lastStartupLoad = Date.distantPast
    private var pendingRefresh: TaskManagerPage?
    private var accounts: [UInt32: (String, String)] = [:]

    func refreshAuthorization() {
        queue.async {
            let enabled = SystemManagementAuthorization.isEnabled
            DispatchQueue.main.async { self.authorized = enabled }
        }
    }

    func activate(_ page: TaskManagerPage) {
        activePage = page
        message = nil
        timer?.invalidate()
        refresh(page: page)
        if page == .services || page == .users {
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh(page: page) }
        }
    }
    func deactivate(_ page: TaskManagerPage) {
        if activePage == page { activePage = nil; timer?.invalidate(); timer = nil }
    }

    func refresh(page: TaskManagerPage, force: Bool = false) {
        guard !isLoading, !isWorking else {
            if force || activePage == page { pendingRefresh = page }
            return
        }
        guard [.services, .startup, .users].contains(page) else { return }
        if page == .startup && !force && Date().timeIntervalSince(lastStartupLoad) < 30 { return }
        isLoading = true
        queue.async {
            let authorized = SystemManagementAuthorization.isEnabled
            if page == .users {
                var console: uid_t = 0
                let consoleName = SCDynamicStoreCopyConsoleUser(nil, &console, nil) as String?
                let sessionResult = Result { try ManagementCommand.run("/usr/bin/who", []) }
                let sessions = (try? sessionResult.get()).map { Set($0.split(separator: "\n").compactMap { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) }) }
                DispatchQueue.main.async {
                    self.authorized = authorized
                    self.consoleUID = consoleName == nil || consoleName == "loginwindow" ? nil : console
                    self.sessionAccounts = sessions ?? []
                    if self.activePage == page, case .failure(let error) = sessionResult { self.message = error.localizedDescription }
                    self.finishRefresh()
                }
                return
            }
            var warnings: [String] = []
            var services: [ServiceRecord] = []
            do { services += try ServiceCatalog.userSnapshot() } catch { warnings.append("用户服务：\(error.localizedDescription)") }
            do { services += try authorized ? SystemManagementXPC.snapshot() : ServiceCatalog.systemSnapshot(runtime: false) }
            catch { warnings.append("系统服务：\(error.localizedDescription)") }
            let enriched = services.map { service -> ServiceRecord in
                var entry = service
                if let name = StartupCatalog.applicationName(entry.programPath) { entry.summary = name }
                return entry
            }
            var items: [StartupItem]?
            if page == .startup {
                var backgroundOutput: String?
                if authorized {
                    do { backgroundOutput = try SystemManagementXPC.backgroundItems() }
                    catch { warnings.append("后台项目：\(error.localizedDescription)") }
                }
                let result = StartupCatalog.load(services: enriched, backgroundOutput: backgroundOutput)
                items = result.items
                warnings += result.warnings
            }
            let finalWarnings = warnings
            let finalItems = items
            DispatchQueue.main.async {
                self.authorized = authorized
                self.services = enriched
                if let finalItems { self.startup = finalItems; self.lastStartupLoad = Date() }
                if self.activePage == page && !finalWarnings.isEmpty { self.message = finalWarnings.joined(separator: "\n") }
                self.finishRefresh()
            }
        }
    }

    private func finishRefresh() {
        isLoading = false
        if let page = pendingRefresh {
            pendingRefresh = nil
            if activePage == page { refresh(page: page, force: true) }
        }
    }

    func enableSystemManagement() {
        perform { try SystemManagementAuthorization.install() }
    }
    func removeSystemManagement() {
        let alert = NSAlert()
        alert.messageText = "移除系统管理助手？"
        alert.informativeText = "将停止本软件管理第三方系统服务的能力。风扇控制和使用历史不受影响。"
        alert.addButton(withTitle: "移除"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform { try SystemManagementAuthorization.uninstall() }
    }
    func operate(_ operation: ServiceOperation, service: ServiceRecord) {
        guard service.manageable else { message = service.protectionReason ?? "此服务无法管理。"; return }
        if [.stop, .restart, .disable].contains(operation) {
            let alert = NSAlert()
            let title = operation == .stop ? "停止" : operation == .restart ? "重启" : "禁用"
            alert.messageText = "\(title) \(service.name)？"
            alert.informativeText = "相关应用的后台功能可能受到影响。\n\(service.identifier.key)"
            alert.addButton(withTitle: title); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        perform {
            if service.identifier.domain == "system" {
                if !SystemManagementAuthorization.isEnabled { try SystemManagementAuthorization.install() }
                try SystemManagementXPC.perform(operation, identifier: service.identifier)
            }
            else { try ServiceCatalog.operate(operation, identifier: service.identifier) }
        }
    }
    func setStartup(_ item: StartupItem, enabled: Bool) {
        if item.requiresSettings { FanHelperRegistration.openSystemSettings(); return }
        if let id = item.service, let service = services.first(where: { $0.identifier == id }) {
            operate(enabled ? .enable : .disable, service: service)
        } else if let url = item.legacyURL { perform { try StartupCatalog.setLegacy(url, enabled: enabled) } }
    }

    private func perform(_ action: @escaping () throws -> Void) {
        guard !isWorking, !isLoading else { return }
        isWorking = true
        queue.async {
            let result = Result { try action() }
            let authorized = SystemManagementAuthorization.isEnabled
            DispatchQueue.main.async {
                self.isWorking = false; self.authorized = authorized
                if case .failure(let error) = result {
                    self.message = error.localizedDescription.contains("(-128)") ? "已取消管理员授权，监控仍可正常使用。" : error.localizedDescription
                }
                self.lastStartupLoad = .distantPast
                if let page = self.activePage { self.refresh(page: page, force: true) }
            }
        }
    }

    func users(from processes: [AppProcess]) -> [ManagedUser] {
        let groups = Dictionary(grouping: processes.filter { process in
            guard let uid = process.metadata.uid else { return false }
            return uid == getuid() || (uid >= 500 && !process.user.hasPrefix("_")) || uid == 201
        }, by: { $0.metadata.uid! })
        var uids = Set(groups.keys)
        uids.insert(getuid())
        for account in sessionAccounts { if let record = getpwnam(account), record.pointee.pw_uid >= 500 { uids.insert(record.pointee.pw_uid) } }
        return uids.map { uid in
            if accounts[uid] == nil {
                if let record = getpwuid(uid) {
                    let name = String(cString: record.pointee.pw_name)
                    let full = String(cString: record.pointee.pw_gecos).components(separatedBy: ",")[0]
                    accounts[uid] = (full.isEmpty ? name : full, name)
                } else { accounts[uid] = (String(uid), String(uid)) }
            }
            let account = accounts[uid]!
            let status = consoleUID == uid ? "当前控制台用户" : sessionAccounts.contains(account.1) ? "已登录" : groups[uid] == nil ? "未知" : "后台进程"
            return ManagedUser(uid: uid, name: account.0, account: account.1, state: status, processes: groups[uid] ?? [])
        }
    }

    func showProperties(_ service: ServiceRecord) {
        properties = ManagementProperties(title: service.name, fields: [
            ("名称", service.name), ("描述", service.summary), ("运行域", service.identifier.domain), ("Label", service.identifier.label),
            ("状态", service.state), ("PID", service.pid.map(String.init) ?? "—"), ("启用状态", service.enabled.map { $0 ? "已启用" : "已禁用" } ?? "未知"),
            ("最近退出码", service.lastExit.map(String.init) ?? "—"), ("配置路径", service.plistPath ?? "—"),
            ("程序路径", service.programPath ?? "—"), ("管理权限", service.protectionReason ?? (service.identifier.domain == "system" ? "需要系统管理授权" : "当前用户可管理"))
        ], path: service.plistPath ?? service.programPath, opensLoginSettings: true)
    }

    func showProperties(_ item: StartupItem) {
        properties = ManagementProperties(title: item.name, fields: [("名称", item.name), ("发布者", item.publisher),
            ("状态", item.state), ("启动影响", item.impact), ("来源", item.source), ("目标路径", item.path ?? "—"),
            ("标识", item.id), ("说明", item.protectionReason ?? (item.requiresSettings ? "由 macOS 登录项设置管理。" : "—"))], path: item.path, opensLoginSettings: true)
    }

    func showProperties(_ process: AppProcess) {
        properties = ManagementProperties(title: process.name, fields: [("名称", process.name), ("PID", String(process.pid)),
            ("父 PID", String(process.parentPID)), ("用户", process.user), ("UID", process.metadata.uid.map(String.init) ?? "—"),
            ("状态", process.metadata.state), ("体系结构", process.metadata.architecture),
            ("启动时间", process.metadata.identity.map { $0.startDate.formatted(date: .numeric, time: .standard) } ?? "—"),
            ("程序路径", process.metadata.executablePath ?? "—")], path: process.metadata.executablePath)
    }
}
