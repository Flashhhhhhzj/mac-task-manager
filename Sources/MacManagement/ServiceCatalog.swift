import Foundation
import Darwin
import MacSMC

public struct ManagementFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum ManagementCommand {
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 6) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        task.environment = environment
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        let finished = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in finished.signal() }
        try task.run()
        let reader = CommandOutput()
        let readFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            reader.data = pipe.fileHandleForReading.readDataToEndOfFile()
            readFinished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            task.terminate()
            if finished.wait(timeout: .now() + 0.5) != .success { kill(task.processIdentifier, SIGKILL) }
            throw ManagementFailure("系统命令超时，请重试。")
        }
        guard readFinished.wait(timeout: .now() + 2) == .success else { throw ManagementFailure("无法读取系统命令结果。") }
        guard reader.data.count < 8 * 1_024 * 1_024 else { throw ManagementFailure("系统返回的数据过大。") }
        let output = String(decoding: reader.data, as: UTF8.self)
        guard task.terminationStatus == 0 else {
            throw ManagementFailure(String(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1200)))
        }
        return output
    }
}

private final class CommandOutput: @unchecked Sendable { var data = Data() }

public struct ServiceIdentifier: Hashable, Codable {
    public let domain: String
    public let label: String
    public init(domain: String, label: String) { self.domain = domain; self.label = label }
    public var key: String { "\(domain)/\(label)" }
}

public struct ServiceRecord: Codable, Identifiable, Equatable {
    public var id: String { identifier.key }
    public let identifier: ServiceIdentifier
    public var name: String
    public var summary: String
    public var plistPath: String?
    public var programPath: String?
    public var startsAutomatically: Bool
    public var enabled: Bool?
    public var loaded: Bool?
    public var pid: Int32?
    public var lastExit: Int32?
    public var protectionReason: String?
    public var manageable: Bool { protectionReason == nil && plistPath != nil }
    public var state: String {
        if enabled == false { return "已禁用" }
        if let pid, pid > 0 { return "正在运行" }
        if loaded == true { return "等待触发" }
        if loaded == false { return "已停止" }
        return "未知"
    }
}

public enum ServiceOperation: String, Codable { case enable, disable, start, stop, restart }

public enum ServiceCatalog {
    public static func filteredBackgroundItems(_ text: String, uid: UInt32) throws -> String {
        guard text.contains("Records for UID ") else { throw ManagementFailure("无法识别 macOS 后台项目列表。") }
        var include = false
        var result: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Records for UID ") {
                let owner = Int64(trimmed.dropFirst("Records for UID ".count).prefix { $0 == "-" || $0.isNumber })
                include = owner == Int64(uid) || owner == -2
            }
            if include { result.append(line) }
        }
        return result.joined(separator: "\n")
    }

    public static func parseList(_ text: String) throws -> [String: (pid: Int32?, exit: Int32)] {
        let lines = text.split(separator: "\n")
        guard let header = lines.first, header.split(whereSeparator: \.isWhitespace).map(String.init) == ["PID", "Status", "Label"] else {
            throw ManagementFailure("无法识别 launchd 服务列表，已停止管理操作。")
        }
        var entries: [String: (Int32?, Int32)] = [:]
        for line in lines.dropFirst() {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3, let status = Int32(fields[1]), fields[0] == "-" || Int32(fields[0]) != nil else {
                throw ManagementFailure("launchd 服务列表不完整。")
            }
            entries[String(fields[2])] = (Int32(fields[0]), status)
        }
        return entries
    }

    public static func parseDisabled(_ text: String) throws -> [String: Bool] {
        guard text.contains("disabled services = {"), text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("}") else {
            throw ManagementFailure("无法读取服务启用状态。")
        }
        let pattern = #"^\s*"([^"]+)"\s*=>\s*(true|false|enabled|disabled)\s*$"#
        let expression = try NSRegularExpression(pattern: pattern)
        var result: [String: Bool] = [:]
        for line in text.components(separatedBy: "\n") where line.contains("=>") {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = expression.firstMatch(in: line, range: range),
                  let name = Range(match.range(at: 1), in: line), let value = Range(match.range(at: 2), in: line) else {
                throw ManagementFailure("无法识别服务启用状态。")
            }
            result[String(line[name])] = line[value] == "true" || line[value] == "disabled"
        }
        return result
    }

    public static func userSnapshot() throws -> [ServiceRecord] {
        try snapshot(domain: "gui/\(getuid())", directories: [
            NSHomeDirectory() + "/Library/LaunchAgents", "/Library/LaunchAgents", "/System/Library/LaunchAgents"
        ], runtime: true)
    }

    public static func systemSnapshot(runtime: Bool) throws -> [ServiceRecord] {
        if runtime && geteuid() != 0 { throw ManagementFailure("读取完整系统服务状态需要启用系统管理助手。") }
        return try snapshot(domain: "system", directories: ["/Library/LaunchDaemons", "/System/Library/LaunchDaemons"], runtime: runtime)
    }

    private static func snapshot(domain: String, directories: [String], runtime: Bool) throws -> [ServiceRecord] {
        var records: [String: ServiceRecord] = [:]
        for directory in directories {
            let urls: [URL]
            do { urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil) }
            catch let error as NSError where error.code == NSFileReadNoSuchFileError { continue }
            for url in urls where url.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: url),
                      let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                      let label = plist["Label"] as? String, validLabel(label) else { continue }
                let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
                var protected: String?
                if directory.hasPrefix("/System/") || label.hasPrefix("com.apple.") { protected = "macOS 系统服务只读。" }
                else if label.hasPrefix("local.Mac-TaskManager.") { protected = "请在设置中移除本软件的控制助手。" }
                else { protected = nil }
                if domain == "system", protected == nil {
                    do { try verifySystemConfiguration(url.path, label: label) }
                    catch { protected = "系统服务配置或程序可被普通用户修改，已设为只读。\n\(error.localizedDescription)" }
                }
                let record = ServiceRecord(identifier: ServiceIdentifier(domain: domain, label: label), name: label,
                    summary: (plist["Description"] as? String) ?? label, plistPath: url.path, programPath: program,
                    startsAutomatically: (plist["RunAtLoad"] as? Bool == true) || (plist["KeepAlive"] as? Bool == true) || (plist["KeepAlive"] is [String: Any]) || plist["StartCalendarInterval"] != nil || plist["StartInterval"] != nil,
                    enabled: nil, loaded: nil, pid: nil, lastExit: nil, protectionReason: protected)
                if var duplicate = records[label] {
                    duplicate.protectionReason = "存在同名服务配置，请先检查配置来源。"
                    records[label] = duplicate
                } else { records[label] = record }
            }
        }
        guard runtime else { return Array(records.values) }
        let loaded = try parseList(ManagementCommand.run("/bin/launchctl", ["list"]))
        let disabled = try parseDisabled(ManagementCommand.run("/bin/launchctl", ["print-disabled", domain]))
        for label in Set(records.keys).union(loaded.keys) {
            var entry = records[label] ?? ServiceRecord(identifier: ServiceIdentifier(domain: domain, label: label), name: label,
                summary: label, plistPath: nil, programPath: nil, startsAutomatically: false, enabled: nil, loaded: nil, pid: nil, lastExit: nil,
                protectionReason: "此动态服务没有可安全管理的独立配置文件。")
            if let disabledValue = disabled[label] { entry.enabled = !disabledValue }
            else if let path = entry.plistPath, let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                    let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
                entry.enabled = !(plist["Disabled"] as? Bool ?? false)
            }
            entry.loaded = loaded[label] != nil
            entry.pid = loaded[label]?.pid
            entry.lastExit = loaded[label]?.exit
            records[label] = entry
        }
        return Array(records.values)
    }

    public static func validLabel(_ label: String) -> Bool {
        !label.isEmpty && label.utf8.count <= 512 && !label.contains("/") && !label.contains("\0") && !label.hasPrefix("-")
            && !label.contains(where: \.isWhitespace)
    }

    public static func verifySystemConfiguration(_ path: String, label: String) throws {
        guard path.hasPrefix("/Library/LaunchDaemons/"), URL(fileURLWithPath: path).deletingLastPathComponent().path == "/Library/LaunchDaemons" else {
            throw ManagementFailure("系统服务配置不在支持的目录中。")
        }
        try FanHelperInstallation.verifyPath(path)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Label"] as? String == label,
              let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first,
              program.hasPrefix("/"), plist["RootDirectory"] == nil else {
            throw ManagementFailure("系统服务标识或程序路径无效。")
        }
        try FanHelperInstallation.verifyPath(program)
        if let directory = plist["WorkingDirectory"] as? String { try FanHelperInstallation.verifyPath(directory, directory: true) }
        for argument in (plist["ProgramArguments"] as? [String] ?? []).dropFirst() where argument.hasPrefix("/") && FileManager.default.fileExists(atPath: argument) {
            var directory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: argument, isDirectory: &directory)
            try FanHelperInstallation.verifyPath(argument, directory: directory.boolValue)
        }
    }

    public static func operate(_ operation: ServiceOperation, identifier: ServiceIdentifier) throws {
        let system = identifier.domain == "system"
        guard validLabel(identifier.label), system ? geteuid() == 0 : identifier.domain == "gui/\(getuid())" else {
            throw ManagementFailure("服务运行域或授权不匹配。")
        }
        let snapshot = try system ? systemSnapshot(runtime: true) : userSnapshot()
        guard let record = snapshot.first(where: { $0.identifier == identifier }), record.manageable,
              let path = record.plistPath else { throw ManagementFailure("此服务受系统保护或没有可管理的配置文件。") }
        if system { try verifySystemConfiguration(path, label: identifier.label) }
        let target = identifier.key
        func write(_ arguments: [String]) throws { try ManagementCommand.run("/bin/launchctl", arguments, timeout: 15) }
        switch operation {
        case .enable, .disable:
            try write([operation.rawValue, target])
            let after = try parseDisabled(ManagementCommand.run("/bin/launchctl", ["print-disabled", identifier.domain]))
            guard after[identifier.label] == (operation == .disable) else { throw ManagementFailure("系统未确认启用状态变更。") }
        case .start:
            guard record.enabled == true else { throw ManagementFailure("服务已禁用或状态未知，请先在启动应用中启用。") }
            if record.loaded == false { try write(["bootstrap", identifier.domain, path]) }
            let current = try system ? systemSnapshot(runtime: true) : userSnapshot()
            do {
                if current.first(where: { $0.identifier == identifier })?.pid == nil { try write(["kickstart", target]) }
            }
            catch {
                if record.loaded == false { _ = try? ManagementCommand.run("/bin/launchctl", ["bootout", target]) }
                throw ManagementFailure("服务未能启动，请检查 macOS 登录项中的后台运行许可。\n\(error.localizedDescription)")
            }
        case .stop:
            guard record.loaded == true else { throw ManagementFailure("服务已停止。") }
            try write(["bootout", target])
        case .restart:
            guard record.loaded == true, record.enabled == true else { throw ManagementFailure("请先启用并启动服务。") }
            try write(["kickstart", "-k", target])
        }
        let refreshed = try system ? systemSnapshot(runtime: true) : userSnapshot()
        guard let after = refreshed.first(where: { $0.identifier == identifier }) else { throw ManagementFailure("操作后无法复查服务状态。") }
        switch operation {
        case .start, .restart:
            guard after.loaded == true else { throw ManagementFailure("服务没有成功加载。") }
            if let code = after.lastExit, code != 0, after.pid == nil { throw ManagementFailure("服务已退出，退出码：\(code)。") }
        case .stop: guard after.loaded == false else { throw ManagementFailure("服务仍处于加载状态。") }
        case .enable, .disable: break
        }
    }
}
