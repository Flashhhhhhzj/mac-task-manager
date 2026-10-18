import CryptoKit
import Darwin
import Foundation

public struct FanHelperInstallation: Codable, Equatable {
    public static let directory = "/Library/Application Support/Mac-TaskManager"
    public static let recordPath = "\(directory)/fan-helper.json"
    public static let recoveryPath = "\(directory)/controlled-fans.json"
    public static let helperPath = "/Library/PrivilegedHelperTools/\(FanControlXPC.serviceName)"
    public static let plistPath = "/Library/LaunchDaemons/\(FanControlXPC.launchDaemonPlistName)"

    public let version: String
    public let authorizedUserIDs: [UInt32]
    public let helperSHA256: String

    public init(authorizedUserIDs: [UInt32], helperSHA256: String) {
        version = FanControlXPC.protocolVersion
        self.authorizedUserIDs = Array(Set(authorizedUserIDs)).sorted()
        self.helperSHA256 = helperSHA256
    }

    public var isValid: Bool {
        version == FanControlXPC.protocolVersion
            && !authorizedUserIDs.isEmpty
            && authorizedUserIDs.allSatisfy { $0 > 0 }
            && helperSHA256.count == 64
            && helperSHA256.allSatisfy { "0123456789abcdef".contains($0) }
    }

    // Unsigned builds grant fixed fan operations to an OS user, not a bundle name.
    public func allowsUser(_ uid: UInt32) -> Bool {
        isValid && (uid == 0 || authorizedUserIDs.contains(uid))
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public enum InstallationError: LocalizedError {
        case unsafePath(String)
        case invalidRecord
        case rootRequired

        public var errorDescription: String? {
            switch self {
            case .unsafePath(let path): return "服务文件权限或路径异常，已拒绝使用：\(path)"
            case .invalidRecord: return "风扇服务安装记录无效，请重新授权修复服务。"
            case .rootRequired: return "安装风扇服务需要通过系统管理员授权。"
            }
        }
    }

    public static func isSecureNode(owner: UInt32, mode: UInt16, directory: Bool) -> Bool {
        owner == 0 && mode & 0o022 == 0
            && mode & UInt16(S_IFMT) == UInt16(directory ? S_IFDIR : S_IFREG)
    }

    public static func verifyPath(_ path: String, directory: Bool = false) throws {
        var info = stat()
        guard lstat(path, &info) == 0,
              isSecureNode(owner: info.st_uid, mode: info.st_mode, directory: directory) else {
            throw InstallationError.unsafePath(path)
        }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if path != "/", parent != path {
            try verifyPath(parent, directory: true)
        }
    }

    public static func load() throws -> FanHelperInstallation? {
        var info = stat()
        guard lstat(recordPath, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw InstallationError.unsafePath(recordPath)
        }
        try verifyPath(recordPath)
        let data = try Data(contentsOf: URL(fileURLWithPath: recordPath))
        let record = try JSONDecoder().decode(Self.self, from: data)
        guard record.isValid else { throw InstallationError.invalidRecord }
        return record
    }

    public static func writeProtectedData(_ data: Data, to path: String, mode: Int = 0o644) throws {
        guard geteuid() == 0 else { throw InstallationError.rootRequired }
        try verifyPath(URL(fileURLWithPath: path).deletingLastPathComponent().path, directory: true)
        var info = stat()
        if lstat(path, &info) == 0 { try verifyPath(path) }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([
            .ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: mode
        ], ofItemAtPath: path)
    }

    public static var launchDaemonPropertyList: [String: Any] {
        [
            "Label": FanControlXPC.serviceName,
            "ProgramArguments": [helperPath],
            "MachServices": [FanControlXPC.serviceName: true],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 5,
            "ProcessType": "Interactive"
        ]
    }
}
