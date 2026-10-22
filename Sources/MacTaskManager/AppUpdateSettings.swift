import SwiftUI

struct AppUpdateSettings: View {
    @ObservedObject var updates: AppUpdateController
    @ObservedObject var dropdownCoordinator: SettingsDropdownCoordinator

    var body: some View {
        VStack(spacing: 12) {
            SettingsOptionRow(
                icon: "arrow.triangle.2.circlepath",
                title: "自动检查更新",
                subtitle: "每天检查正式版，发现更新后自动下载，安装前询问你"
            ) {
                SettingsDropdown(
                    selection: Binding(
                        get: { updates.automaticChecks ? "开启" : "关闭" },
                        set: { updates.setAutomaticChecks($0 == "开启") }
                    ),
                    options: ["开启", "关闭"],
                    identifier: "automatic-updates",
                    dropdownCoordinator: dropdownCoordinator
                )
            }
            .zIndex(dropdownCoordinator.expandedIdentifier == "automatic-updates" ? 10 : 0)

            SettingsOptionRow(
                icon: "arrow.down.circle",
                title: "软件更新",
                subtitle: updates.status
            ) {
                Group {
                    if updates.phase == .ready {
                        Button("更新并重启") { updates.confirmInstallation() }
                            .buttonStyle(FanPrimaryButtonStyle())
                    } else if updates.canCancel {
                        Button("取消") { updates.cancel() }
                            .buttonStyle(.bordered)
                    } else {
                        Button(updates.phase == .idle ? "检查更新" : "正在更新…") { updates.checkForUpdates() }
                            .buttonStyle(FanPrimaryButtonStyle())
                            .disabled(!updates.canCheck)
                    }
                }
                .frame(width: 130)
            }
            .help(updates.status)

            if [.downloading, .preparing].contains(updates.phase) {
                if let progress = updates.progress {
                    ProgressView(value: progress).tint(TaskManagerStyle.accent)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            HStack {
                if let checked = updates.lastChecked {
                    Text("上次检查：\(checked.formatted(date: .abbreviated, time: .shortened))")
                }
                Spacer()
                if let url = updates.releaseURL {
                    Link("查看更新内容", destination: url)
                }
            }
            .font(.system(size: 13))
            .foregroundColor(TaskManagerStyle.muted)
        }
    }
}
