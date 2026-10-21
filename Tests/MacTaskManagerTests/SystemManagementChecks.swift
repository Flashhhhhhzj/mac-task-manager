import Foundation
import MacManagement

@main
enum SystemManagementChecks {
    static func main() throws {
        let list = try ServiceCatalog.parseList("PID\tStatus\tLabel\n123\t0\torg.example.running\n-\t-15\torg.example.waiting\n")
        precondition(list["org.example.running"]?.pid == 123 && list["org.example.waiting"]?.pid == nil)
        precondition(list["org.example.waiting"]?.exit == -15)
        let disabled = try ServiceCatalog.parseDisabled("disabled services = {\n\t\"org.example.off\" => true\n\t\"org.example.on\" => false\n}")
        precondition(disabled["org.example.off"] == true && disabled["org.example.on"] == false)
        let named = try ServiceCatalog.parseDisabled("disabled services = {\n\t\"org.example.off\" => disabled\n\t\"org.example.on\" => enabled\n}")
        precondition(named == disabled, "Both supported launchctl status formats must map to the same state")
        mustFail { _ = try ServiceCatalog.parseList("unexpected format") }
        mustFail { _ = try ServiceCatalog.parseDisabled("not authorized") }
        mustFail { _ = try ServiceCatalog.parseDisabled("disabled services = {\n x => perhaps\n}") }
        precondition(!ServiceCatalog.validLabel("../evil") && !ServiceCatalog.validLabel("-system") && !ServiceCatalog.validLabel("a b"))
        mustFail { try ServiceCatalog.operate(.start, identifier: ServiceIdentifier(domain: "system", label: "../evil")) }
        mustFail { try ServiceCatalog.operate(.stop, identifier: ServiceIdentifier(domain: "gui/9999999", label: "org.example.safe")) }
        mustFail { try SystemHelperInstallation.install(sourceURL: URL(fileURLWithPath: "/does-not-exist"), uid: 0) }
        mustFail { try ServiceCatalog.verifySystemConfiguration("/tmp/user-writable.plist", label: "org.example.unsafe") }
        let uid = getuid()
        let output = """
        Records for UID \(uid):
        #1:
          Name: Ordinary installed app
          Type: app (0x2)
          Identifier: org.example.installed
        #2:
          Name: Enabled login item
          Type: login item (0x4)
          Disposition: [enabled, allowed, notified] (0xb)
          Identifier: org.example.login
          URL: file:///Applications/Example.app
        #3:
          Name: Disabled agent
          Type: legacy agent (0x10008)
          Disposition: [disabled, allowed, notified] (0xa)
          Identifier: org.example.agent
        #4:
          Name: Awaiting permission
          Type: agent (0x8)
          Disposition: [enabled, disallowed, notified] (0x9)
          Identifier: org.example.denied
        #5:
          Name: Main app login
          Type: app (0x2)
          Disposition: [enabled, allowed, not notified] (0x3)
          Identifier: org.example.main
          URL: file:///Applications/Main.app
        #6:
          Name: Disabled main login
          Type: app (0x2)
          Disposition: [disabled, allowed, notified] (0xa)
          Identifier: org.example.oldmain
        #7:
          Name: Background owner
          Type: app (0x2)
          Disposition: [disabled, allowed, notified] (0xa)
          Identifier: org.example.owner
          URL: file:///Applications/Owner.app
          Embedded Item Identifiers:
            #1: org.example.child
        #8:
          Name: Embedded login
          Type: login item (0x4)
          Disposition: [enabled, allowed, notified] (0xb)
          Identifier: org.example.child
          Parent Identifier: org.example.owner
          URL: Contents/Library/LoginItems/Child.app
        #9:
          Name: Protected fan helper
          Type: legacy daemon (0x10010)
          Disposition: [enabled, allowed, notified] (0xb)
          Identifier: 16.local.Mac-TaskManager.FanHelper.v2
          Developer Name:
        Records for UID \(uid + 1000):
        #1:
          Name: Other user's login item
          Type: login item (0x4)
          Identifier: org.example.private
        """
        let items = StartupCatalog.parseBTM(output, uid: uid)
        let filtered = try ServiceCatalog.filteredBackgroundItems(output, uid: uid)
        precondition(!filtered.contains("org.example.private") && filtered.contains("org.example.main"))
        mustFail { _ = try ServiceCatalog.filteredBackgroundItems("not permitted", uid: uid) }
        precondition(items.count == 7 && !items.contains { ["org.example.installed", "org.example.private", "org.example.owner"].contains($0.backgroundIdentifier ?? "") })
        precondition(items.first { $0.backgroundIdentifier == "org.example.login" }?.enabled == true)
        precondition(items.first { $0.backgroundIdentifier == "org.example.agent" }?.path == nil)
        precondition(items.first { $0.backgroundIdentifier == "org.example.denied" }?.state == "等待系统允许")
        precondition(items.first { $0.backgroundIdentifier == "org.example.main" }?.enabled == true)
        precondition(items.first { $0.backgroundIdentifier == "org.example.oldmain" }?.enabled == false)
        precondition(items.first { $0.backgroundIdentifier == "org.example.child" }?.path == "/Applications/Owner.app/Contents/Library/LoginItems/Child.app")
        let helper = items.first { $0.backgroundIdentifier == "local.Mac-TaskManager.FanHelper.v2" }
        precondition(helper?.requiresSettings == false && helper?.protectionReason != nil && helper?.publisher == "—")
        if ProcessInfo.processInfo.environment["CI"] == nil {
            let user = try ServiceCatalog.userSnapshot()
            precondition(Set(user.map(\.id)).count == user.count)
            precondition(user.filter { $0.identifier.label.hasPrefix("com.apple.") }.allSatisfy { !$0.manageable })
            let startup = StartupCatalog.load(services: user)
            precondition(!startup.items.isEmpty)
            print("Live read-only catalog: \(user.count) user services; \(startup.items.count) startup records; warnings: \(startup.warnings.count)")
            for warning in startup.warnings { print("Catalog warning: \(warning)") }
        }
        print("SystemManagementChecks: parser failures, domain validation, protected targets and BTM privacy passed")
    }
    private static func mustFail(_ block: () throws -> Void) {
        do { try block(); preconditionFailure("An invalid request was accepted") } catch { }
    }
}
