import SwiftUI

struct SystemManagementSettings: View {
    @ObservedObject var workspace: ManagementWorkspace
    var body: some View {
        SettingsOptionRow(icon: "lock.shield", title: "系统管理服务",
                          subtitle: workspace.authorized ? "已授权当前账户管理第三方系统启动项与服务" : "首次管理第三方系统服务时需要管理员批准") {
            if workspace.isWorking {
                ProgressView().controlSize(.small)
            } else if workspace.authorized {
                Button("移除服务", action: workspace.removeSystemManagement).buttonStyle(.bordered)
            } else {
                Button("启用 / 修复", action: workspace.enableSystemManagement).buttonStyle(.borderedProminent)
            }
        }
        .onAppear { workspace.refreshAuthorization() }
        .alert("系统管理", isPresented: Binding(get: { workspace.message != nil }, set: { if !$0 { workspace.message = nil } })) {
            Button("确定") { workspace.message = nil }
        } message: { Text(workspace.message ?? "") }
    }
}
