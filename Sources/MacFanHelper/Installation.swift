import Darwin
import Foundation
import MacSMC

enum HelperInstaller {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func install(for uid: UInt32) throws {
        guard geteuid() == 0 else { throw FanHelperInstallation.InstallationError.rootRequired }
        guard uid > 0, getpwuid(uid) != nil else {
            throw Failure(message: "无法识别需要授权的本机用户。")
        }
        umask(0o022)
        for path in ["/Library/PrivilegedHelperTools", "/Library/LaunchDaemons",
                     "/Library/Application Support", FanHelperInstallation.directory] {
            try ensureDirectory(path)
        }

        let source = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let binary = try Data(contentsOf: source)
        guard !binary.isEmpty, binary.count < 50_000_000 else {
            throw Failure(message: "应用包中的风扇服务文件无效，请重新下载完整安装包。")
        }
        let previous = try? FanHelperInstallation.load()
        let record = FanHelperInstallation(
            authorizedUserIDs: (previous?.authorizedUserIDs ?? []) + [uid],
            helperSHA256: FanHelperInstallation.digest(binary)
        )
        let paths = [FanHelperInstallation.helperPath, FanHelperInstallation.recordPath,
                     FanHelperInstallation.plistPath]
        var backups: [String: Data] = [:]
        for path in paths where FileManager.default.fileExists(atPath: path) {
            try FanHelperInstallation.verifyPath(path)
            backups[path] = try Data(contentsOf: URL(fileURLWithPath: path))
        }
        let legacyLoaded = (try? launchctl(["print", "system/\(FanControlXPC.legacyServiceName)"])) != nil
        do {
            try stopService(FanControlXPC.serviceName)
            if legacyLoaded {
                try launchctl(["disable", "system/\(FanControlXPC.legacyServiceName)"])
                try stopService(FanControlXPC.legacyServiceName)
                let controller = try SMCController()
                let indexes = try controller.snapshot().fans.filter(\.isManual).map(\.index)
                if !indexes.isEmpty {
                    try FanHelperInstallation.writeProtectedData(JSONEncoder().encode(indexes),
                        to: FanHelperInstallation.recoveryPath, mode: 0o600)
                }
            }
            try FanHelperInstallation.writeProtectedData(binary, to: FanHelperInstallation.helperPath, mode: 0o755)
            try FanHelperInstallation.writeProtectedData(JSONEncoder().encode(record), to: FanHelperInstallation.recordPath)
            let plist = try PropertyListSerialization.data(
                fromPropertyList: FanHelperInstallation.launchDaemonPropertyList,
                format: .xml, options: 0
            )
            try FanHelperInstallation.writeProtectedData(plist, to: FanHelperInstallation.plistPath)
            try launchctl(["enable", "system/\(FanControlXPC.serviceName)"])
            try launchctl(["bootstrap", "system", FanHelperInstallation.plistPath])
            try FanControlXPC.checkConnection()
        } catch {
            let installationError = error
            try? stopService(FanControlXPC.serviceName)
            try? restoreJournal()
            for path in paths {
                if let data = backups[path] {
                    try? FanHelperInstallation.writeProtectedData(data, to: path,
                        mode: path == FanHelperInstallation.helperPath ? 0o755 : 0o644)
                } else {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
            if backups[FanHelperInstallation.plistPath] != nil {
                _ = try? launchctl(["bootstrap", "system", FanHelperInstallation.plistPath])
            }
            if legacyLoaded { _ = try? launchctl(["enable", "system/\(FanControlXPC.legacyServiceName)"]) }
            throw installationError
        }
    }

    static func uninstall() throws {
        guard geteuid() == 0 else { throw FanHelperInstallation.InstallationError.rootRequired }
        try stopService(FanControlXPC.serviceName)
        do {
            try restoreJournal()
        } catch {
            _ = try? launchctl(["bootstrap", "system", FanHelperInstallation.plistPath])
            throw error
        }
        for path in [FanHelperInstallation.helperPath, FanHelperInstallation.plistPath,
                     FanHelperInstallation.recordPath, FanHelperInstallation.recoveryPath] {
            if FileManager.default.fileExists(atPath: path) {
                try FanHelperInstallation.verifyPath(path)
                try FileManager.default.removeItem(atPath: path)
            }
        }
    }

    static func restoreJournal() throws {
        let indexes = try recoveryIndexes()
        guard !indexes.isEmpty else { return }
        let controller = try SMCController()
        for index in indexes { try controller.setFanAutomatic(index: index) }
        try FanHelperInstallation.writeProtectedData(Data("[]".utf8), to: FanHelperInstallation.recoveryPath, mode: 0o600)
    }

    static func recoveryIndexes() throws -> [Int] {
        let path = FanHelperInstallation.recoveryPath
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        try FanHelperInstallation.verifyPath(path)
        let indexes = try JSONDecoder().decode([Int].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard indexes.count <= 32, indexes.allSatisfy({ (0..<256).contains($0) }) else {
            throw Failure(message: "风扇恢复记录无效，已停止控制服务。")
        }
        return Array(Set(indexes)).sorted()
    }

    private static func ensureDirectory(_ path: String) throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try FanHelperInstallation.verifyPath(parent, directory: true)
        if mkdir(path, 0o755) != 0, errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try FanHelperInstallation.verifyPath(path, directory: true)
    }

    private static func stopService(_ name: String) throws {
        if (try? launchctl(["print", "system/\(name)"])) != nil {
            try launchctl(["bootout", "system/\(name)"])
        }
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw Failure(message: "系统无法配置风扇服务：\(output)")
        }
        return output
    }
}
