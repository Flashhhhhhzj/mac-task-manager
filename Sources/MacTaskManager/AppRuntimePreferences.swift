import Foundation
import AppKit
import ServiceManagement

enum AppRuntimePreferences {
    static let launchAtLoginKey = "LaunchAtLoginEnabled"
    static let hideMainWindowAtLoginKey = "HideMainWindowAtLoginEnabled"
    static let keepRunningAfterWindowCloseKey = "KeepRunningAfterWindowCloseEnabled"
    static let hideDockIconKey = "HideDockIconEnabled"

    static var hidesDockIcon: Bool {
        UserDefaults.standard.bool(forKey: hideDockIconKey)
    }

    static func setHidesDockIcon(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: hideDockIconKey)
        applyDockIconPreference()
    }

    static func applyDockIconPreference() {
        NSApp.setActivationPolicy(hidesDockIcon ? .accessory : .regular)
    }

    static var isLaunchAtLoginEnabled: Bool {
        bool(forKey: launchAtLoginKey)
    }

    static var hidesMainWindowAtLogin: Bool {
        UserDefaults.standard.bool(forKey: hideMainWindowAtLoginKey)
    }

    static func setHidesMainWindowAtLogin(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: hideMainWindowAtLoginKey)
    }

    static func shouldHideMainWindowOnLaunch(event: NSAppleEventDescriptor?) -> Bool {
        hidesMainWindowAtLogin && event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    static var keepsRunningAfterWindowClose: Bool {
        bool(forKey: keepRunningAfterWindowCloseKey)
    }

    static func setLaunchAtLoginEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: launchAtLoginKey)
        applyLaunchAtLoginPreference()
    }

    static func setKeepsRunningAfterWindowClose(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: keepRunningAfterWindowCloseKey)
    }

    static func applyLaunchAtLoginPreference() {
        let service = SMAppService.mainApp

        do {
            if isLaunchAtLoginEnabled {
                guard service.status != .enabled else { return }
                try service.register()
            } else {
                guard service.status != .notRegistered else { return }
                try service.unregister()
            }
        } catch {
            // A debug executable cannot register itself as a login item. The
            // packaged app retries this preference on its next launch.
            NSLog("Unable to update Mac-TaskManager launch-at-login setting: %@", error.localizedDescription)
        }
    }

    private static func bool(forKey key: String) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }
}
