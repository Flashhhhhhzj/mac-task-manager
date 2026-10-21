import Foundation
import Darwin
import MacManagement
import MacSMC

final class SystemService: NSObject, SystemManagementProtocol {
    private static let queue = DispatchQueue(label: "local.Mac-TaskManager.system-management")
    private let uid: UInt32
    init(uid: UInt32) { self.uid = uid }
    func ping(withReply reply: @escaping (String) -> Void) { reply(SystemManagementXPC.version) }
    func services(withReply reply: @escaping (Data?, String?) -> Void) {
        Self.queue.async {
            do { reply(try JSONEncoder().encode(ServiceCatalog.systemSnapshot(runtime: true)), nil) }
            catch { reply(nil, error.localizedDescription) }
        }
    }
    func backgroundItems(withReply reply: @escaping (String?, String?) -> Void) {
        Self.queue.async {
            do {
                let output = try ManagementCommand.run("/usr/bin/sfltool", ["dumpbtm"], timeout: 20)
                reply(try ServiceCatalog.filteredBackgroundItems(output, uid: self.uid), nil)
            } catch { reply(nil, error.localizedDescription) }
        }
    }
    func operate(_ operation: String, label: String, withReply reply: @escaping (Bool, String?) -> Void) {
        Self.queue.async {
            do {
                guard let action = ServiceOperation(rawValue: operation), ServiceCatalog.validLabel(label) else { throw ManagementFailure("无效的服务操作。") }
                try ServiceCatalog.operate(action, identifier: ServiceIdentifier(domain: "system", label: label))
                reply(true, nil)
            } catch { reply(false, error.localizedDescription) }
        }
    }
}

final class SystemListener: NSObject, NSXPCListenerDelegate {
    let record: SystemHelperInstallation
    init(_ record: SystemHelperInstallation) { self.record = record }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard record.authorizedUserIDs.contains(connection.effectiveUserIdentifier) else { return false }
        connection.exportedInterface = NSXPCInterface(with: SystemManagementProtocol.self)
        connection.exportedObject = SystemService(uid: connection.effectiveUserIdentifier)
        connection.resume()
        return true
    }
}

do {
    let args = CommandLine.arguments
    if args.count == 3, args[1] == "install", let uid = UInt32(args[2]) {
        try SystemHelperInstallation.install(sourceURL: URL(fileURLWithPath: args[0]), uid: uid)
    } else if args.count == 2, args[1] == "uninstall" {
        try SystemHelperInstallation.uninstall()
    } else if args.count == 1 {
        guard geteuid() == 0, let record = try SystemHelperInstallation.load() else { throw ManagementFailure("系统助手需要管理员安装。") }
        try FanHelperInstallation.verifyPath(SystemHelperInstallation.helperPath)
        let binary = try Data(contentsOf: URL(fileURLWithPath: SystemHelperInstallation.helperPath))
        guard FanHelperInstallation.digest(binary) == record.helperSHA256 else { throw ManagementFailure("系统助手文件校验失败。") }
        let delegate = SystemListener(record)
        let listener = NSXPCListener(machServiceName: SystemManagementXPC.serviceName)
        listener.delegate = delegate
        listener.resume()
        withExtendedLifetime((listener, delegate)) { RunLoop.current.run() }
    } else { throw ManagementFailure("用法：MacSystemHelper install <UID> | uninstall") }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(EXIT_FAILURE)
}
