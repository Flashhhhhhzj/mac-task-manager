import Darwin
import Foundation
import MacSMC

private enum HelperCommand {
    case status
    case temperatureKeys
    case install(UInt32)
    case uninstall

    init(arguments: [String]) throws {
        if arguments.count == 3, arguments[1] == "install", let uid = UInt32(arguments[2]) {
            self = .install(uid)
            return
        }
        guard arguments.count == 2 else { throw HelperError.usage }
        switch arguments[1] {
        case "status": self = .status
        case "temperature-keys": self = .temperatureKeys
        case "uninstall": self = .uninstall
        default: throw HelperError.usage
        }
    }
}

private enum HelperError: LocalizedError {
    case rootRequired
    case invalidRequest
    case recovering
    case usage

    var errorDescription: String? {
        switch self {
        case .rootRequired: return "风扇服务必须由系统管理员授权安装后启动。"
        case .invalidRequest: return "风扇控制参数无效。"
        case .recovering: return "正在将上次中断的风扇控制恢复为系统自动，请稍后重试。"
        case .usage: return "用法：MacFanHelper status | temperature-keys | install <用户 UID> | uninstall"
        }
    }
}

private final class FanControlService: NSObject, FanControlXPCProtocol {
    private let queue = DispatchQueue(label: "local.Mac-TaskManager.FanHelper.operations", qos: .userInitiated)
    private var controlledFanIndexes: Set<Int>
    private var coolModeFanIndexes = Set<Int>()
    private var lastCoolModeTargets: [Int: Double] = [:]
    private var lastHeartbeat = Date.distantPast
    private var recovering: Bool
    private var watchdog: DispatchSourceTimer?

    init(recoveryIndexes: [Int]) {
        controlledFanIndexes = Set(recoveryIndexes)
        recovering = !recoveryIndexes.isEmpty
        super.init()
        let watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .now() + 1, repeating: 1)
        watchdog.setEventHandler { [weak self] in
            guard let self, !self.controlledFanIndexes.isEmpty,
                  self.recovering || Date().timeIntervalSince(self.lastHeartbeat) >= 10 else { return }
            try? self.restore(self.controlledFanIndexes, using: SMCController())
        }
        watchdog.resume()
        self.watchdog = watchdog
    }

    deinit { watchdog?.cancel() }

    func ping(withReply reply: @escaping (Bool, String?) -> Void) {
        reply(true, FanControlXPC.protocolVersion)
    }

    func heartbeat(withReply reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            if !self.recovering { self.lastHeartbeat = Date() }
            reply(true, nil)
        }
    }

    func restoreAll(withReply reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            do {
                if !self.controlledFanIndexes.isEmpty {
                    try self.restore(self.controlledFanIndexes, using: SMCController())
                }
                reply(true, nil)
            } catch { reply(false, error.localizedDescription) }
        }
    }

    func setFanRPM(index: Int, rpm: Double, withReply reply: @escaping (Bool, String?) -> Void) {
        perform(reply) { controller in
            try self.restore(self.coolModeFanIndexes, using: controller)
            try self.track(index, using: controller)
            try controller.setFanRPM(index: index, rpm: rpm)
        }
    }

    func setFanAutomatic(index: Int, withReply reply: @escaping (Bool, String?) -> Void) {
        perform(reply) { controller in
            try self.restore(self.coolModeFanIndexes, using: controller)
            try controller.setFanAutomatic(index: index)
            self.controlledFanIndexes.remove(index)
            try self.saveJournal()
        }
    }

    func updateCoolModeTargets(indexes: [NSNumber], rpms: [NSNumber],
                               withReply reply: @escaping (Bool, String?) -> Void) {
        perform(reply) { controller in
            guard !indexes.isEmpty, indexes.count <= 32, indexes.count == rpms.count,
                  indexes.allSatisfy({ $0.doubleValue.isFinite && $0.doubleValue == Double($0.intValue) }),
                  Set(indexes.map(\.intValue)).count == indexes.count,
                  rpms.allSatisfy({ $0.doubleValue.isFinite }) else { throw HelperError.invalidRequest }
            for (indexValue, rpmValue) in zip(indexes, rpms) {
                let index = indexValue.intValue
                let rpm = rpmValue.doubleValue
                if self.lastCoolModeTargets[index].map({ abs($0 - rpm) >= 50 }) ?? true {
                    try self.track(index, using: controller)
                    try controller.setFanRPM(index: index, rpm: rpm)
                    self.lastCoolModeTargets[index] = rpm
                }
                self.coolModeFanIndexes.insert(index)
            }
        }
    }

    func stopCoolMode(withReply reply: @escaping (Bool, String?) -> Void) {
        perform(reply) { controller in try self.restore(self.coolModeFanIndexes, using: controller) }
    }

    func shutdown() {
        queue.sync {
            if !controlledFanIndexes.isEmpty {
                try? restore(controlledFanIndexes, using: SMCController())
            }
        }
    }

    private func perform(_ reply: @escaping (Bool, String?) -> Void,
                         _ operation: @escaping (SMCController) throws -> Void) {
        queue.async {
            do {
                guard !self.recovering else { throw HelperError.recovering }
                try operation(SMCController())
                self.lastHeartbeat = Date()
                reply(true, nil)
            } catch {
                // A failed write may already have switched a fan to manual mode.
                if !self.controlledFanIndexes.isEmpty {
                    try? self.restore(self.controlledFanIndexes, using: SMCController())
                }
                reply(false, error.localizedDescription)
            }
        }
    }

    private func track(_ index: Int, using controller: SMCController) throws {
        guard (0..<min(try controller.fanCount(), 32)).contains(index) else { throw HelperError.invalidRequest }
        controlledFanIndexes.insert(index)
        // Persist the intent before touching hardware so a restarted helper can recover it.
        try saveJournal()
    }

    private func saveJournal() throws {
        try FanHelperInstallation.writeProtectedData(JSONEncoder().encode(controlledFanIndexes.sorted()),
            to: FanHelperInstallation.recoveryPath, mode: 0o600)
    }

    private func restore(_ indexes: Set<Int>, using controller: SMCController) throws {
        guard !indexes.isEmpty else { return }
        var firstError: Error?
        for index in indexes.sorted() {
            do {
                try controller.setFanAutomatic(index: index)
                controlledFanIndexes.remove(index)
                coolModeFanIndexes.remove(index)
                lastCoolModeTargets.removeValue(forKey: index)
            } catch { if firstError == nil { firstError = error } }
        }
        try saveJournal()
        if controlledFanIndexes.isEmpty { recovering = false }
        if let firstError { throw firstError }
    }
}

private final class FanControlListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service: FanControlService
    private let installation: FanHelperInstallation

    init(installation: FanHelperInstallation, recoveryIndexes: [Int]) {
        self.installation = installation
        service = FanControlService(recoveryIndexes: recoveryIndexes)
        super.init()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard installation.allowsUser(connection.effectiveUserIdentifier) else { return false }
        connection.exportedInterface = NSXPCInterface(with: FanControlXPCProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

private func runDaemon() throws -> Never {
    guard geteuid() == 0 else { throw HelperError.rootRequired }
    guard let installation = try FanHelperInstallation.load() else {
        throw FanHelperInstallation.InstallationError.invalidRecord
    }
    try FanHelperInstallation.verifyPath(FanHelperInstallation.helperPath)
    let binary = try Data(contentsOf: URL(fileURLWithPath: FanHelperInstallation.helperPath))
    guard FanHelperInstallation.digest(binary) == installation.helperSHA256 else {
        throw FanHelperInstallation.InstallationError.invalidRecord
    }
    let delegate = FanControlListenerDelegate(installation: installation,
        recoveryIndexes: try HelperInstaller.recoveryIndexes())
    let listener = NSXPCListener(machServiceName: FanControlXPC.serviceName)
    listener.delegate = delegate
    listener.resume()

    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    for source in [termination, interruption] {
        source.setEventHandler { delegate.service.shutdown(); exit(EXIT_SUCCESS) }
        source.resume()
    }
    withExtendedLifetime((listener, delegate, termination, interruption)) { RunLoop.current.run() }
    fatalError("风扇控制服务意外退出")
}

private func runCommandLineTool() throws {
    let command = try HelperCommand(arguments: CommandLine.arguments)
    switch command {
    case .status:
        let snapshot = try SMCController().snapshot()
        print("model=\(snapshot.hardwareModel) fans=\(snapshot.fans.count)")
        for fan in snapshot.fans {
            print(
                "fan=\(fan.index) actual=\(Int(fan.actualRPM)) target=\(Int(fan.targetRPM)) " +
                "minimum=\(Int(fan.minimumRPM)) maximum=\(Int(fan.maximumRPM)) " +
                "mode=\(fan.isManual ? "manual" : "automatic")"
            )
        }
        print("temperatures=\(snapshot.temperatures.count)")
        for sensor in snapshot.temperatures {
            print(
                "sensor=\(sensor.key) group=\(sensor.group.rawValue) " +
                "name=\(sensor.name) celsius=\(String(format: "%.1f", sensor.celsius))"
            )
        }
    case .install(let uid):
        try HelperInstaller.install(for: uid)
        print("风扇控制服务已安装，当前用户已获授权。")
    case .uninstall:
        try HelperInstaller.uninstall()
        print("风扇控制服务已移除。")
    case .temperatureKeys:
        for sensor in try SMCController().availableTemperatureKeys() {
            print("\(sensor.key)=\(String(format: "%.1f", sensor.celsius))")
        }
    }
}

do {
    if CommandLine.arguments.count == 1 {
        try runDaemon()
    } else {
        try runCommandLineTool()
    }
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
