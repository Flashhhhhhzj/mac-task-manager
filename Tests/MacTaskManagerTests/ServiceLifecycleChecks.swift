import Foundation
import MacManagement

@main
enum ServiceLifecycleChecks {
    static func main() throws {
        let label = "local.MacTaskManager.Validation." + UUID().uuidString
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(label + ".plist")
        let identifier = ServiceIdentifier(domain: "gui/\(getuid())", label: label)
        defer {
            _ = try? ManagementCommand.run("/bin/launchctl", ["bootout", identifier.key])
            try? FileManager.default.removeItem(at: url)
        }
        let plist: [String: Any] = ["Label": label, "ProgramArguments": ["/bin/sleep", "120"], "KeepAlive": true, "RunAtLoad": true]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        progress("start")
        try ServiceCatalog.operate(.start, identifier: identifier)
        let running = try record(identifier)
        precondition(running.loaded == true && running.pid != nil)
        progress("restart")
        try ServiceCatalog.operate(.restart, identifier: identifier)
        precondition(tryLoaded(identifier))
        progress("stop")
        try ServiceCatalog.operate(.stop, identifier: identifier)
        Thread.sleep(forTimeInterval: 0.3)
        let stopped = try record(identifier)
        precondition(stopped.loaded == false && stopped.pid == nil && stopped.enabled == true, "Stopping a KeepAlive service must unload it without disabling future startup")
        progress("reload")
        try ServiceCatalog.operate(.start, identifier: identifier)
        precondition(tryLoaded(identifier))
        print("ServiceLifecycleChecks: dedicated user service start, restart, KeepAlive stop and reload passed; test job cleaned up")
    }
    private static func record(_ id: ServiceIdentifier) throws -> ServiceRecord {
        guard let record = try ServiceCatalog.userSnapshot().first(where: { $0.identifier == id }) else { throw ManagementFailure("Missing validation job") }
        return record
    }
    private static func tryLoaded(_ id: ServiceIdentifier) -> Bool { (try? record(id).loaded) == true }
    private static func progress(_ stage: String) { FileHandle.standardOutput.write(Data("Service lifecycle: \(stage)\n".utf8)) }
}
