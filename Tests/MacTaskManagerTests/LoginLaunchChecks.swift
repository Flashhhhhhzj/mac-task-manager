import AppKit

@main
enum LoginLaunchChecks {
    static func main() {
        let defaults = UserDefaults.standard
        let key = AppRuntimePreferences.hideMainWindowAtLoginKey
        let original = defaults.object(forKey: key)
        defer {
            if let original { defaults.set(original, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        let loginEvent = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        loginEvent.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        defaults.removeObject(forKey: key)
        precondition(!AppRuntimePreferences.shouldHideMainWindowOnLaunch(event: loginEvent), "Default must preserve visible startup")
        AppRuntimePreferences.setHidesMainWindowAtLogin(true)
        precondition(AppRuntimePreferences.shouldHideMainWindowOnLaunch(event: loginEvent), "Enabled login launch must stay in the background")
        precondition(!AppRuntimePreferences.shouldHideMainWindowOnLaunch(event: nil), "Manual launch must still show the window")
        loginEvent.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsServiceItem), forKeyword: keyAEPropData)
        precondition(!AppRuntimePreferences.shouldHideMainWindowOnLaunch(event: loginEvent), "Other launch reasons must not be mistaken for login")
        AppRuntimePreferences.setHidesMainWindowAtLogin(false)
        loginEvent.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        precondition(!AppRuntimePreferences.shouldHideMainWindowOnLaunch(event: loginEvent), "Disabled preference must show the login window")
        print("LoginLaunchChecks: default, login, manual, service and disabled launches passed")
    }
}
