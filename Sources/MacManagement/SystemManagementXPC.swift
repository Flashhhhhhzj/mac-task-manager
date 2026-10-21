import Foundation
import MacSMC
import Darwin

@objc public protocol SystemManagementProtocol {
    func ping(withReply reply: @escaping (String) -> Void)
    func services(withReply reply: @escaping (Data?, String?) -> Void)
    func backgroundItems(withReply reply: @escaping (String?, String?) -> Void)
    func operate(_ operation: String, label: String, withReply reply: @escaping (Bool, String?) -> Void)
}

public enum SystemManagementXPC {
    public static let serviceName = "local.Mac-TaskManager.SystemHelper.v1"
    public static let version = "1"

    public static func snapshot() throws -> [ServiceRecord] {
        let data: Data = try request { proxy, finish in
            proxy.services { data, error in
                if let data { finish(.success(data)) }
                else { finish(.failure(ManagementFailure(error ?? "无法读取系统服务。"))) }
            }
        }
        return try JSONDecoder().decode([ServiceRecord].self, from: data)
    }

    public static func perform(_ operation: ServiceOperation, identifier: ServiceIdentifier) throws {
        guard identifier.domain == "system" else { throw ManagementFailure("系统助手只管理系统运行域。") }
        let _: Data = try request(timeout: 90) { proxy, finish in
            proxy.operate(operation.rawValue, label: identifier.label) { success, error in
                finish(success ? .success(Data()) : .failure(ManagementFailure(error ?? "系统服务操作失败。")))
            }
        }
    }

    public static func backgroundItems() throws -> String {
        let data = try request { proxy, finish in
            proxy.backgroundItems { text, error in
                if let text { finish(.success(Data(text.utf8))) }
                else { finish(.failure(ManagementFailure(error ?? "无法读取后台项目。"))) }
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func request(timeout: TimeInterval = 30, _ operation: @escaping (SystemManagementProtocol, @escaping (Result<Data, Error>) -> Void) -> Void) throws -> Data {
        let record = try SystemHelperInstallation.load()
        guard record?.authorizedUserIDs.contains(getuid()) == true else { throw ManagementFailure("请先启用系统管理功能。") }
        let result = ManagementReply()
        let connection = NSXPCConnection(machServiceName: serviceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: SystemManagementProtocol.self)
        connection.interruptionHandler = { result.finish(.failure(ManagementFailure("系统管理服务连接中断。"))) }
        connection.invalidationHandler = { result.finish(.failure(ManagementFailure("系统管理服务连接已失效。"))) }
        connection.resume()
        defer { connection.interruptionHandler = nil; connection.invalidationHandler = nil; connection.invalidate() }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ result.finish(.failure($0)) }) as? SystemManagementProtocol else {
            throw ManagementFailure("无法连接系统管理服务。")
        }
        proxy.ping { version in
            guard version == Self.version, connection.effectiveUserIdentifier == 0 else {
                result.finish(.failure(ManagementFailure("系统管理服务身份或版本不匹配。"))); return
            }
            operation(proxy) { result.finish($0) }
        }
        guard result.semaphore.wait(timeout: .now() + timeout) == .success else { throw ManagementFailure("系统管理服务响应超时，请刷新检查实际状态。") }
        return try result.value!.get()
    }
}

private final class ManagementReply {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    var value: Result<Data, Error>?
    func finish(_ result: Result<Data, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard value == nil else { return }
        value = result; semaphore.signal()
    }
}

public struct SystemHelperInstallation: Codable {
    public static let helperPath = "/Library/PrivilegedHelperTools/\(SystemManagementXPC.serviceName)"
    public static let plistPath = "/Library/LaunchDaemons/\(SystemManagementXPC.serviceName).plist"
    public static let recordPath = FanHelperInstallation.directory + "/system-helper.json"
    public let version: String
    public let authorizedUserIDs: [UInt32]
    public let helperSHA256: String

    public static func load() throws -> Self? {
        guard FileManager.default.fileExists(atPath: recordPath) else { return nil }
        try FanHelperInstallation.verifyPath(recordPath)
        let record = try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: recordPath)))
        guard record.version == SystemManagementXPC.version, !record.authorizedUserIDs.isEmpty,
              record.authorizedUserIDs.allSatisfy({ $0 > 0 }), record.helperSHA256.count == 64,
              record.helperSHA256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw ManagementFailure("系统管理助手授权记录无效。")
        }
        return record
    }

    public static func isCurrent(bundledURL: URL) throws -> Bool {
        guard let record = try load(), record.authorizedUserIDs.contains(getuid()) else { return false }
        try FanHelperInstallation.verifyPath(helperPath)
        try FanHelperInstallation.verifyPath(plistPath)
        let bundleData = try Data(contentsOf: bundledURL)
        let installedData = try Data(contentsOf: URL(fileURLWithPath: helperPath))
        return FanHelperInstallation.digest(bundleData) == record.helperSHA256 && FanHelperInstallation.digest(installedData) == record.helperSHA256
    }

    public static func install(sourceURL: URL, uid: UInt32) throws {
        guard geteuid() == 0, uid > 0, getpwuid(uid) != nil else { throw ManagementFailure("系统助手安装需要有效用户及管理员授权。") }
        let bytes = try Data(contentsOf: sourceURL)
        guard !bytes.isEmpty, bytes.count < 50_000_000 else { throw ManagementFailure("系统管理助手文件无效。") }
        umask(0o022)
        let directory = FanHelperInstallation.directory
        for path in ["/Library/PrivilegedHelperTools", "/Library/LaunchDaemons", "/Library/Application Support", directory] {
            if !FileManager.default.fileExists(atPath: path) {
                try FanHelperInstallation.verifyPath(URL(fileURLWithPath: path).deletingLastPathComponent().path, directory: true)
                guard mkdir(path, 0o755) == 0 else { throw POSIXError(.EACCES) }
            }
            try FanHelperInstallation.verifyPath(path, directory: true)
        }
        let previous = try load()
        let record = Self(version: SystemManagementXPC.version,
            authorizedUserIDs: Array(Set((previous?.authorizedUserIDs ?? []) + [uid])).sorted(), helperSHA256: FanHelperInstallation.digest(bytes))
        let paths = [helperPath, plistPath, recordPath]
        var old: [String: Data] = [:]
        for path in paths where FileManager.default.fileExists(atPath: path) {
            try FanHelperInstallation.verifyPath(path)
            old[path] = try Data(contentsOf: URL(fileURLWithPath: path))
        }
        let wasLoaded = (try? ManagementCommand.run("/bin/launchctl", ["print", "system/\(SystemManagementXPC.serviceName)"])) != nil
        if wasLoaded { try ManagementCommand.run("/bin/launchctl", ["bootout", "system/\(SystemManagementXPC.serviceName)"]) }
        do {
            try FanHelperInstallation.writeProtectedData(bytes, to: helperPath, mode: 0o755)
            let plist: [String: Any] = ["Label": SystemManagementXPC.serviceName, "ProgramArguments": [helperPath],
                "MachServices": [SystemManagementXPC.serviceName: true], "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 5]
            try FanHelperInstallation.writeProtectedData(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: plistPath)
            try FanHelperInstallation.writeProtectedData(JSONEncoder().encode(record), to: recordPath)
            try ManagementCommand.run("/bin/launchctl", ["enable", "system/\(SystemManagementXPC.serviceName)"])
            try ManagementCommand.run("/bin/launchctl", ["bootstrap", "system", plistPath])
        } catch {
            _ = try? ManagementCommand.run("/bin/launchctl", ["bootout", "system/\(SystemManagementXPC.serviceName)"])
            for path in paths {
                if let data = old[path] { try? FanHelperInstallation.writeProtectedData(data, to: path, mode: path == helperPath ? 0o755 : 0o644) }
                else { try? FileManager.default.removeItem(atPath: path) }
            }
            if wasLoaded { _ = try? ManagementCommand.run("/bin/launchctl", ["bootstrap", "system", plistPath]) }
            throw error
        }
    }

    public static func uninstall() throws {
        guard geteuid() == 0 else { throw ManagementFailure("移除系统助手需要管理员授权。") }
        _ = try load()
        for path in [helperPath, plistPath, recordPath] where FileManager.default.fileExists(atPath: path) { try FanHelperInstallation.verifyPath(path) }
        if (try? ManagementCommand.run("/bin/launchctl", ["print", "system/\(SystemManagementXPC.serviceName)"])) != nil {
            try ManagementCommand.run("/bin/launchctl", ["bootout", "system/\(SystemManagementXPC.serviceName)"])
        }
        for path in [helperPath, plistPath, recordPath] where FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
    }
}
