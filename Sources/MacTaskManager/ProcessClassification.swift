import AppKit

func isApplicationProcess(activationPolicy: NSApplication.ActivationPolicy?, bundleURL: URL?) -> Bool {
    if activationPolicy == .regular { return true }
    guard activationPolicy == .accessory, let bundleURL,
          bundleURL.pathExtension.lowercased() == "app" else { return false }

    let parent = bundleURL.standardizedFileURL.deletingLastPathComponent()
    // Accessory apps include system agents and nested helpers as well as menu-bar apps.
    guard !parent.pathComponents.contains(where: {
        ["app", "appex", "xpc"].contains(($0 as NSString).pathExtension.lowercased())
    }) else { return false }
    return !FileManager.default.urls(for: .libraryDirectory, in: .allDomainsMask).contains {
        let library = $0.standardizedFileURL.path
        return parent.path == library || parent.path.hasPrefix(library + "/")
    }
}
