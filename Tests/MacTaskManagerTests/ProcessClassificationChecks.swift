import AppKit

@main
enum ProcessClassificationChecks {
    static func main() {
        check(.regular, nil, expected: true)
        check(.regular, "/Users/example/Downloads/Normal App.app", expected: true)
        check(nil, "/Applications/Unknown.app", expected: false)
        check(.prohibited, "/Applications/Background.app", expected: false)
        check(.prohibited, "/Applications/Notes.app/Contents/PlugIns/NotesWidget.appex", expected: false)

        for path in ["/Applications/Paste.app", "/Users/example/Downloads/Menu Tool.app", "/System/Applications/Siri.app"] {
            check(.accessory, path, expected: true)
        }
        for path in [
            "/Applications/Paste.app/Contents/Library/LoginItems/Paste Helper.app",
            "/Applications/Browser.app/Contents/Frameworks/Renderer.app",
            "/Applications/Notes.app/Contents/PlugIns/NotesWidget.appex",
            "/Applications/Browser.app/Contents/XPCServices/Renderer.xpc",
            "/System/Library/CoreServices/NotificationCenter.app",
            "/Library/Application Support/Vendor/Service.app",
            NSHomeDirectory() + "/Library/Application Support/Vendor/Agent.app"
        ] {
            check(.accessory, path, expected: false)
        }
        check(.accessory, nil, expected: false)
        print("ProcessClassificationChecks: system roles, menu-bar apps, extensions and helpers passed")
    }

    private static func check(_ policy: NSApplication.ActivationPolicy?, _ path: String?, expected: Bool) {
        let url = path.map { URL(fileURLWithPath: $0) }
        precondition(isApplicationProcess(activationPolicy: policy, bundleURL: url) == expected,
                     "Incorrect classification: \(String(describing: policy)), \(path ?? "no bundle")")
    }
}
