import Foundation
import MacManagement

@main
enum CatalogReadChecks {
    static func main() throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
            FileHandle.standardError.write(Data("CatalogReadChecks exceeded its total time limit\n".utf8))
            exit(1)
        }
        stage("large input")
        let payload = Data(repeating: 65, count: 256 * 1_024)
        let echoed = try ManagementCommand.run("/bin/cat", [], input: payload)
        precondition(Data(echoed.utf8) == payload, "A request larger than the pipe buffer must not deadlock")
        let started = Date()
        stage("timeout")
        do {
            try ManagementCommand.run("/bin/sleep", ["10"], timeout: 0.1)
            preconditionFailure("A blocked catalog must time out")
        } catch { precondition(Date().timeIntervalSince(started) < 3) }
        stage("output limit")
        do {
            try ManagementCommand.run("/usr/bin/yes", [], timeout: 3)
            preconditionFailure("Unbounded command output must be rejected")
        } catch { precondition(error.localizedDescription.contains("数据过大")) }
        let ready = try ManagementCommand.run("/bin/echo", ["ready"])
        precondition(ready.trimmingCharacters(in: .whitespacesAndNewlines) == "ready")
        stage("root and relative paths")
        for path in ["/", "", "/usr/bin/true", "//", "/../", "relative/tool", "/Applications/Foo.app/../../tool"] {
            precondition(StartupCatalog.enclosingApplication(path) == nil)
        }
        precondition(StartupCatalog.enclosingApplication("/Applications/Foo.app/Contents/MacOS/Foo")?.path == "/Applications/Foo.app")
        precondition(StartupCatalog.enclosingApplication("/Applications/Foo.app/Contents/Helpers/Bar.app/Contents/MacOS/Bar")?.path == "/Applications/Foo.app/Contents/Helpers/Bar.app")
        let helper = CommandLine.arguments[1]
        var records: [ServiceRecord] = []
        for scope in ["user", "system"] {
            stage("catalog-\(scope)")
            let text = try ManagementCommand.run(helper, ["catalog-\(scope)"], timeout: 8)
            records += try JSONDecoder().decode([ServiceRecord].self, from: Data(text.utf8))
        }
        precondition(!records.isEmpty)
        let base = StartupCatalog.serviceItems(records)
        precondition(Set(base.map(\.id)).count == base.count)
        let request = StartupCatalogRequest(services: records, backgroundOutput: nil)
        stage("catalog-startup")
        let text = try ManagementCommand.run(helper, ["catalog-startup"], timeout: 10, input: JSONEncoder().encode(request))
        let result = try JSONDecoder().decode(StartupCatalogResult.self, from: Data(text.utf8))
        precondition(Set(result.items.map(\.id)).count == result.items.count)
        print("CatalogReadChecks: bounded input/output, timeout recovery, root paths and read-only catalogs passed (\(records.count) services, \(result.items.count) startup items)")
    }
    private static func stage(_ name: String) { print("CatalogReadChecks: \(name)"); fflush(stdout) }
}
