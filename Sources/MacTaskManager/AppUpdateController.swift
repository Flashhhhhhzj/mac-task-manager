import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdateController: NSObject, ObservableObject, SPUUserDriver, SPUUpdaterDelegate {
    static let shared = AppUpdateController()

    enum Phase { case idle, checking, downloading, preparing, ready, installing }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = "从 GitHub 获取正式版更新，下载后由你确认安装"
    @Published private(set) var automaticChecks = true
    @Published private(set) var canCheck = false
    @Published private(set) var progress: Double?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var availableVersion: String?
    @Published private(set) var releaseURL: URL?

    private var updater: SPUUpdater?
    private var sessionObservation: NSKeyValueObservation?
    private var cancellation: (() -> Void)?
    private var installationReply: ((SPUUserUpdateChoice) -> Void)?
    private var confirmation: NSAlert?
    private var receivedBytes: UInt64 = 0
    private var expectedBytes: UInt64 = 0
    private var installationApproved = false
    private var terminationPending = false

    var canCancel: Bool { cancellation != nil }

    func start() {
        guard updater == nil else { return }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        self.updater = updater
        do {
            try updater.start()
            automaticChecks = updater.automaticallyChecksForUpdates
            lastChecked = updater.lastUpdateCheckDate
            canCheck = updater.canCheckForUpdates
            sessionObservation = updater.observe(\.sessionInProgress, options: [.new]) { [weak self] _, change in
                let started = change.newValue == true
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.refreshSessionState()
                    if started && self.updater?.sessionInProgress == true && self.phase == .idle {
                        self.phase = .checking
                        self.status = "正在检查更新…"
                    }
                }
            }
        } catch {
            status = "更新服务无法启动：\(error.localizedDescription)"
        }
    }

    func setAutomaticChecks(_ enabled: Bool) {
        updater?.automaticallyChecksForUpdates = enabled
        automaticChecks = updater?.automaticallyChecksForUpdates ?? false
    }

    func checkForUpdates() {
        guard let updater, updater.canCheckForUpdates, !updater.sessionInProgress else { return }
        phase = .checking
        status = "正在检查更新…"
        availableVersion = nil
        releaseURL = nil
        updater.checkForUpdates()
    }

    func cancel() {
        status = "已取消更新，可随时重新检查"
        cancelCurrentUpdate()
    }

    func confirmInstallation() {
        guard installationReply != nil, confirmation == nil else { return }
        AppDelegate.shared?.showMainWindow()
        guard let window = AppDelegate.shared?.mainWindow ?? NSApp.mainWindow else { return }
        let alert = NSAlert()
        alert.messageText = "更新已下载，是否更新并重启？"
        alert.informativeText = "Mac-TaskManager \(availableVersion ?? "新版") 已准备好。更新会退出并重新打开应用，监控会短暂中断。选择暂不更新将取消本次安装。"
        alert.addButton(withTitle: "更新并重启")
        alert.addButton(withTitle: "暂不更新")
        confirmation = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.confirmation = nil
            guard let reply = self.installationReply else { return }
            self.installationReply = nil
            if response == .alertFirstButtonReturn && !self.terminationPending {
                self.installationApproved = true
                self.phase = .installing
                self.status = "正在更新并重启…"
                reply(.install)
            } else {
                self.status = "已暂缓更新，可重新检查并下载"
                // Dismiss would still install on quit; skip cancels this prepared installation.
                reply(.skip)
            }
        }
    }

    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        guard !installationApproved,
              updater?.sessionInProgress == true || installationReply != nil else { return .terminateNow }
        terminationPending = true
        // Sparkle must cancel its prepared installer before the app exits without consent.
        DispatchQueue.main.async { self.cancelCurrentUpdate() }
        return .terminateLater
    }

    private func cancelCurrentUpdate() {
        if let reply = installationReply {
            installationReply = nil
            closeConfirmation()
            reply(.skip)
        } else if let cancel = cancellation {
            cancellation = nil
            cancel()
        }
        // During extraction, wait for showReadyToInstallAndRelaunch and cancel there.
    }

    private func closeConfirmation() {
        if let alert = confirmation, let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
        }
        confirmation = nil
    }

    private func finishPendingTermination() {
        guard terminationPending else { return }
        terminationPending = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private func refreshSessionState() {
        guard let updater else { return }
        canCheck = updater.canCheckForUpdates && !updater.sessionInProgress
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        var supportsARM: Int32 = 0
        var size = MemoryLayout.size(ofValue: supportsARM)
        let isARM = sysctlbyname("hw.optional.arm64", &supportsARM, &size, nil, 0) == 0 && supportsARM == 1
        let arch = isARM ? "arm64" : "x64"
        return "https://github.com/Flashhhhhhzj/mac-task-manager/releases/latest/download/appcast-\(arch).xml"
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: automaticChecks, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        phase = .checking
        status = "正在检查更新…"
        if terminationPending { cancelCurrentUpdate() }
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancellation = nil
        availableVersion = appcastItem.displayVersionString
        if let url = appcastItem.infoURL, url.scheme == "https", url.host == "github.com" {
            releaseURL = url
        }
        if terminationPending {
            reply(state.stage == .installing ? .skip : .dismiss)
        } else if appcastItem.isInformationOnlyUpdate {
            status = "发现新版 \(appcastItem.displayVersionString)，请查看更新说明"
            reply(.dismiss)
        } else if state.stage == .installing {
            showReady(toInstallAndRelaunch: reply)
        } else {
            status = "发现新版 \(appcastItem.displayVersionString)，正在下载…"
            reply(.install)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
        if reason?.intValue == Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue) {
            status = "当前已是最新正式版"
        } else if reason?.intValue == Int(SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue) {
            status = "当前版本已高于最新正式版"
        } else {
            status = error.localizedDescription
        }
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        status = "更新失败：\(error.localizedDescription)"
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        phase = .downloading
        receivedBytes = 0
        expectedBytes = 0
        progress = nil
        if terminationPending { cancelCurrentUpdate() }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += length
        progress = expectedBytes > 0 ? min(1, Double(receivedBytes) / Double(expectedBytes)) : nil
        let received = ByteCountFormatter.string(fromByteCount: Int64(clamping: receivedBytes), countStyle: .file)
        let expected = ByteCountFormatter.string(fromByteCount: Int64(clamping: expectedBytes), countStyle: .file)
        status = "正在下载 \(availableVersion ?? "新版")：\(received)\(expectedBytes > 0 ? " / " + expected : "")"
    }

    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil
        progress = nil
        phase = .preparing
        status = "正在校验并准备更新…"
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        self.progress = min(1, max(0, progress))
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        phase = .ready
        progress = nil
        cancellation = nil
        installationReply = reply
        status = "\(availableVersion ?? "新版") 已下载，等待你确认更新并重启"
        if terminationPending { cancelCurrentUpdate() } else { confirmInstallation() }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        phase = .installing
        status = "正在更新并重启…"
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        status = "更新完成"
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        cancellation = nil
        installationReply = nil
        closeConfirmation()
        progress = nil
        phase = .idle
        installationApproved = false
        refreshSessionState()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        lastChecked = updater.lastUpdateCheckDate
        if let error, (error as NSError).code != Int(SUError.noUpdateError.rawValue) {
            status = "更新未完成：\(error.localizedDescription)"
        } else if (error as NSError?)?.code == Int(SUError.noUpdateError.rawValue), phase == .checking {
            status = "当前没有可安装的正式版更新"
        }
        phase = .idle
        refreshSessionState()
        finishPendingTermination()
    }

    func showUpdateInFocus() {
        if phase == .ready { confirmInstallation() }
    }
}
