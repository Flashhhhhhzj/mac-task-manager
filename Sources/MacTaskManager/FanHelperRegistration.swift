import AppKit
import Darwin
import Foundation
import MacSMC
import ServiceManagement
import SwiftUI

enum FanHelperRegistration {
    private static let onboardingDismissedBuildKey = "FullFunctionalitySystemManagementV1DismissedBuild"
    private static let installationLock = NSLock()
    private static var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/MacFanHelper")
    }
    private static let bundledDigest: String? = {
        guard let data = try? Data(contentsOf: helperURL) else { return nil }
        return FanHelperInstallation.digest(data)
    }()

    enum RegistrationError: LocalizedError {
        case appBundleRequired
        case canceled
        case registrationDenied(String)

        var errorDescription: String? {
            switch self {
            case .appBundleRequired:
                return "请从完整的 Mac-TaskManager.app 打开软件，再启用风扇控制。"
            case .canceled:
                return "已取消授权。你仍可查看监控数据，稍后可在风扇页面重新启用。"
            case .registrationDenied(let reason):
                return "未能完成风扇服务配置，可以重新尝试。\n\n\(reason)"
            }
        }
    }

    static var canRegisterFromCurrentBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && FileManager.default.isExecutableFile(atPath: helperURL.path)
    }

    static var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var wasOnboardingDismissedForCurrentBuild: Bool {
        UserDefaults.standard.string(forKey: onboardingDismissedBuildKey) == currentBuild
    }

    static func dismissOnboardingForCurrentBuild() {
        UserDefaults.standard.set(currentBuild, forKey: onboardingDismissedBuildKey)
    }

    static func authorizationState(checkConnection: Bool = true) -> FanHelperAuthorizationState {
        do {
            guard let record = try FanHelperInstallation.load() else { return .notRegistered }
            guard record.allowsUser(getuid()) else { return .notRegistered }
            guard let bundledDigest, record.helperSHA256 == bundledDigest else { return .needsUpdate }
            try FanHelperInstallation.verifyPath(FanHelperInstallation.helperPath)
            try FanHelperInstallation.verifyPath(FanHelperInstallation.plistPath)
            let installed = try Data(contentsOf: URL(fileURLWithPath: FanHelperInstallation.helperPath))
            guard FanHelperInstallation.digest(installed) == record.helperSHA256 else { return .needsUpdate }
            if checkConnection { try FanControlXPC.checkConnection() }
            return .enabled
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    static func registerOrRefresh() throws {
        try administratorCommand("install")
        guard authorizationState(checkConnection: false).isEnabled else {
            throw RegistrationError.registrationDenied("服务安装后校验未通过，请重新尝试。")
        }
        try FanControlXPC.checkConnection()
        UserDefaults.standard.removeObject(forKey: onboardingDismissedBuildKey)
    }

    static func uninstall() throws {
        try administratorCommand("uninstall")
        dismissOnboardingForCurrentBuild()
    }

    private static func administratorCommand(_ command: String) throws {
        guard canRegisterFromCurrentBundle else { throw RegistrationError.appBundleRequired }
        installationLock.lock()
        defer { installationLock.unlock() }
        let script = """
        on run argv
            set helperPath to item 1 of argv
            set operationName to item 2 of argv
            set userID to item 3 of argv
            set shellCommand to quoted form of helperPath & " " & quoted form of operationName
            if operationName is "install" then set shellCommand to shellCommand & " " & quoted form of userID
            do shell script shellCommand with administrator privileges
        end run
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, "--", helperURL.path, command, String(getuid())]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            if output.contains("(-128)") { throw RegistrationError.canceled }
            throw RegistrationError.registrationDenied(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
final class FirstLaunchAuthorizationModel: ObservableObject {
    enum Phase: Equatable {
        case checking, notRegistered, needsUpdate, requiresApproval, enabled
        case failed(String)
    }

    @Published var isPresented = false
    @Published private(set) var phase: Phase = .checking
    @Published private(set) var isWorking = false
    private var isChecking = false

    func start() {
        guard FanHelperRegistration.canRegisterFromCurrentBundle else { return }
        refresh(presentWhenNeeded: true)
    }

    var canOpenSystemSettings: Bool {
        if case .failed = phase { return true }
        return phase == .requiresApproval
    }

    func refresh(presentWhenNeeded: Bool = false) {
        guard !isWorking, !isChecking else { return }
        isChecking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fanState = FanHelperRegistration.authorizationState()
            let state: FanHelperAuthorizationState = fanState == .enabled && !SystemManagementAuthorization.isEnabled ? .needsUpdate : fanState
            DispatchQueue.main.async {
                self.isChecking = false
                switch state {
                case .enabled:
                    self.phase = .enabled
                    self.isPresented = false
                case .notRegistered: self.phase = .notRegistered
                case .needsUpdate: self.phase = .needsUpdate
                case .requiresApproval: self.phase = .requiresApproval
                case .checking: self.phase = .checking
                case .unavailable(let message): self.phase = .failed(message)
                }
                if state != .enabled && presentWhenNeeded
                    && !FanHelperRegistration.wasOnboardingDismissedForCurrentBuild {
                    self.isPresented = true
                }
            }
        }
    }

    func enableFullFunctionality() {
        guard !isWorking, !isChecking else { return }
        isWorking = true
        phase = .checking
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try SystemManagementAuthorization.install(includeFan: !FanHelperRegistration.authorizationState(checkConnection: false).isEnabled)
            }
            DispatchQueue.main.async {
                self.isWorking = false
                switch result {
                case .success: self.refresh()
                case .failure(let error):
                    self.phase = .failed(error.localizedDescription)
                    self.isPresented = true
                }
            }
        }
    }

    func openSystemSettings() { FanHelperRegistration.openSystemSettings() }

    func dismissForNow() {
        FanHelperRegistration.dismissOnboardingForCurrentBuild()
        isPresented = false
    }
}

struct FirstLaunchAuthorizationView: View {
    @ObservedObject var model: FirstLaunchAuthorizationModel

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(TaskManagerStyle.onboardingAccentSurface)
                    .frame(width: 62, height: 62)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 28))
                    .foregroundColor(Color(red: 0.0, green: 0.40, blue: 0.75))
            }

            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(TaskManagerStyle.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                permissionRow(
                    icon: "checkmark.circle.fill",
                    text: "进程、性能和温度读取无需额外授权"
                )
                permissionRow(
                    icon: "fanblades",
                    text: "授权后可调节风扇，并管理第三方系统启动项与服务"
                )
                permissionRow(
                    icon: "key.fill",
                    text: "首次批准后，日常调整不再重复输入管理员密码"
                )
            }
            .padding(14)
            .background(TaskManagerStyle.elevatedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 12) {
                Button("暂时跳过") {
                    model.dismissForNow()
                }
                .buttonStyle(.bordered)
                .disabled(model.isWorking)

                if model.canOpenSystemSettings {
                    Button("打开系统设置") {
                        model.openSystemSettings()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isWorking)
                }

                Button(primaryButtonTitle) {
                    model.enableFullFunctionality()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking)
            }

            if model.isWorking {
                ProgressView("正在配置风扇控制服务…")
                    .controlSize(.small)
            }
        }
        .padding(28)
        .frame(width: 520)
        .background(TaskManagerStyle.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(TaskManagerStyle.border, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 24, y: 12)
        .accessibilityAddTraits(.isModal)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            model.refresh()
        }
    }

    private var title: String {
        switch model.phase {
        case .checking:
            return "正在检查完整功能"
        case .notRegistered:
            return "启用风扇与系统管理"
        case .needsUpdate:
            return "更新完整功能授权"
        case .requiresApproval:
            return "还需要一次系统批准"
        case .enabled:
            return "完整功能已启用"
        case .failed:
            return "完整功能配置失败"
        }
    }

    private var detail: String {
        switch model.phase {
        case .checking:
            return "正在检查风扇和系统管理服务。"
        case .notRegistered:
            return "点击下方按钮，在系统窗口输入管理员密码，软件会自动完成安装。以后正常使用和重启无需重复授权。"
        case .needsUpdate:
            return "后台服务需要更新或增加系统管理权限。批准后，当前账户可管理第三方系统服务；已有风扇服务无需重复安装。"
        case .requiresApproval:
            return "请在“系统设置 → 通用 → 登录项与扩展 → 允许在后台”中允许 Mac-TaskManager。完成后返回此处点击“重新检查”。"
        case .enabled:
            return "设置已完成，可以使用手动调速、清凉模式及第三方系统服务管理。"
        case .failed(let message):
            return message
        }
    }

    private var primaryButtonTitle: String {
        switch model.phase {
        case .requiresApproval:
            return "重新检查"
        case .needsUpdate:
            return "更新并启用"
        case .failed:
            return "重新尝试"
        default:
            return "启用完整功能"
        }
    }

    private func permissionRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(Color(red: 0.0, green: 0.40, blue: 0.75))
                .frame(width: 18)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(TaskManagerStyle.text)
        }
    }
}
