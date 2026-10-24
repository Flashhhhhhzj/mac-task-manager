import AppKit
import MacManagement

// These checks never open settings or install an authorized helper.
enum FanHelperRegistration { static func openSystemSettings() {} }

@main
enum ManagementLoadingChecks {
    static func main() throws {
        precondition(Bundle.main.bundleIdentifier == "local.MacTaskManager.LoadingChecks", "Run only inside the dedicated test bundle")
        let helper = SystemManagementAuthorization.bundledURL
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        case "$1" in
          catalog-user) printf '%s' '[{"identifier":{"domain":"gui/\(getuid())","label":"org.example.fixture"},"name":"Fixture","summary":"Fixture","plistPath":"/tmp/org.example.fixture.plist","startsAutomatically":true,"enabled":true,"loaded":true}]' ;;
          catalog-system) printf '[]' ;;
          catalog-startup) exec /bin/sleep 30 ;;
          *) exit 1 ;;
        esac
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let workspace = ManagementWorkspace()
        workspace.activate(.startup)
        wait(until: { workspace.startup.count == 1 }, timeout: 3)
        if workspace.startup.isEmpty { print(workspace.diagnostics); fflush(stdout) }
        precondition(workspace.startup.count == 1, "Readable rows must appear before login-item metadata finishes")
        workspace.activate(.services)
        wait(until: { !workspace.isLoading }, timeout: 3)
        precondition(!workspace.isLoading && workspace.services.count == 1, "A blocked startup read must not block Services")
        workspace.deactivate(.services)
        workspace.activate(.startup)
        precondition(workspace.isLoading, "Returning to an in-flight page must retain its own loading state")
        wait(until: { !workspace.isLoading }, timeout: 12)
        precondition(!workspace.isLoading && workspace.startup.count == 1)
        precondition(workspace.message?.contains("登录项目及应用信息") == true, "A timeout must report the failed stage")
        precondition(workspace.diagnostics["启动应用.loading"] == "false")
        workspace.deactivate(.startup)
        print("ManagementLoadingChecks: partial rows, independent pages, timeout and diagnostic state passed")
    }
    private static func wait(until condition: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
}
