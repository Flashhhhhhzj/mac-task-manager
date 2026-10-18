import Darwin
import Foundation
import MacSMC

enum FanHelperAuthorizationChecks {
    static func run() throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw NSError(domain: "FanHelperAuthorizationChecks", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let digest = FanHelperInstallation.digest(Data("abc".utf8))
        try require(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "incorrect helper digest")
        let record = FanHelperInstallation(authorizedUserIDs: [501, 501, 502], helperSHA256: digest)
        try require(record.isValid && record.authorizedUserIDs == [501, 502], "invalid persisted grant")
        try require(record.allowsUser(501) && record.allowsUser(502), "authorized user rejected")
        try require(!record.allowsUser(503), "an unauthorized local user was accepted")
        try require(record.allowsUser(0), "root installer health check was rejected")
        let restored = try JSONDecoder().decode(FanHelperInstallation.self, from: JSONEncoder().encode(record))
        try require(restored == record && restored.allowsUser(501), "grant did not survive reload")
        try require(!FanHelperInstallation(authorizedUserIDs: [], helperSHA256: digest).isValid, "empty grant accepted")
        try require(!FanHelperInstallation(authorizedUserIDs: [0], helperSHA256: digest).isValid, "root used as a user grant")
        try require(!FanHelperInstallation(authorizedUserIDs: [501], helperSHA256: "bad").allowsUser(501), "corrupt digest accepted")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        json["version"] = "obsolete"
        let obsolete = try JSONDecoder().decode(FanHelperInstallation.self,
            from: JSONSerialization.data(withJSONObject: json))
        try require(!obsolete.allowsUser(501), "obsolete protocol granted access")

        let fileMode = UInt16(S_IFREG)
        let dirMode = UInt16(S_IFDIR)
        try require(FanHelperInstallation.isSecureNode(owner: 0, mode: fileMode | 0o755, directory: false), "protected helper rejected")
        try require(FanHelperInstallation.isSecureNode(owner: 0, mode: dirMode | 0o755, directory: true), "protected directory rejected")
        try require(!FanHelperInstallation.isSecureNode(owner: 501, mode: fileMode | 0o755, directory: false), "user-owned helper accepted")
        try require(!FanHelperInstallation.isSecureNode(owner: 0, mode: fileMode | 0o775, directory: false), "group-writable helper accepted")
        try require(!FanHelperInstallation.isSecureNode(owner: 0, mode: dirMode | 0o777, directory: true), "world-writable ancestor accepted")
        try require(!FanHelperInstallation.isSecureNode(owner: 0, mode: UInt16(S_IFLNK) | 0o755, directory: false), "symlink accepted")
        try require(!FanHelperInstallation.isSecureNode(owner: 0, mode: dirMode | 0o755, directory: false), "directory accepted as executable")

        let plist = FanHelperInstallation.launchDaemonPropertyList
        try require(plist["Label"] as? String == FanControlXPC.serviceName, "incorrect launch label")
        try require(plist["ProgramArguments"] as? [String] == [FanHelperInstallation.helperPath], "helper path is not fixed")
        try require(plist["KeepAlive"] as? Bool == true, "crashed helper will not restart")
        try require((plist["MachServices"] as? [String: Bool])?[FanControlXPC.serviceName] == true, "missing XPC endpoint")
        try require(FanControlXPC.serviceName != FanControlXPC.legacyServiceName, "legacy registration can conflict")
        try require(SMCController.isFiniteRPM(1350), "normal RPM rejected")
        for value in [Double.nan, Double.infinity, -Double.infinity, -1, Double(Int64.max)] {
            try require(!SMCController.isFiniteRPM(value), "unsafe RPM accepted")
        }
        if geteuid() != 0 {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
            do {
                try FanHelperInstallation.writeProtectedData(Data(), to: path)
                throw NSError(domain: "FanHelperAuthorizationChecks", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "unprivileged installation was accepted"])
            } catch FanHelperInstallation.InstallationError.rootRequired { }
            try require(!FileManager.default.fileExists(atPath: path), "unprivileged operation created a file")
        }
        print("FanHelperAuthorizationChecks: user grants, protected paths, launchd config, RPM validation passed")
    }
}
