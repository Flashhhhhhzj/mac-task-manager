import AppKit
import SwiftUI

struct TaskManagerOverflowMenuButton: NSViewRepresentable {
    let makeMenu: () -> NSMenu
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.showMenu(_:)))
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "更多选项")?
            .withSymbolConfiguration(.init(pointSize: 19, weight: .semibold))
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.setAccessibilityLabel("更多选项")
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: TaskManagerOverflowMenuButton

        init(_ parent: TaskManagerOverflowMenuButton) { self.parent = parent }

        @objc func showMenu(_ sender: NSButton) {
            let menu = parent.makeMenu()
            menu.appearance = sender.effectiveAppearance
            let bottom = sender.isFlipped ? sender.bounds.maxY + 4 : sender.bounds.minY - 4
            menu.popUp(positioning: nil,
                       at: NSPoint(x: sender.bounds.maxX - menu.minimumWidth, y: bottom), in: sender)
        }
    }
}

final class TaskManagerMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }
}

struct ProcessOverflowMenuButton: View {
    let monitor: SystemMonitor
    let state: ContentViewState
    let selectedProcess: AppProcess?

    var body: some View { TaskManagerOverflowMenuButton(makeMenu: makeMenu) }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.font = .systemFont(ofSize: 14)
        menu.minimumWidth = 190

        let viewMenu = NSMenu(title: "视图")
        viewMenu.autoenablesItems = false
        viewMenu.font = menu.font
        viewMenu.minimumWidth = 170
        let grouped = TaskManagerMenuItem("按类型分组", action: toggleGrouping)
        grouped.state = state.groupProcessesByType ? .on : .off
        viewMenu.addItem(grouped)
        viewMenu.addItem(TaskManagerMenuItem("全部展开", action: expandAll))
        viewMenu.addItem(TaskManagerMenuItem("全部折叠", action: collapseAll))

        let view = NSMenuItem(title: "视图", action: nil, keyEquivalent: "")
        view.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        // macOS 27 normally hides menu icons; use its public setter without requiring the newer SDK.
        let imageVisibility = NSSelectorFromString("setPreferredImageVisibility:")
        if view.responds(to: imageVisibility) { view.setValue(1, forKey: "preferredImageVisibility") }
        view.submenu = viewMenu
        menu.addItem(view)
        menu.addItem(.separator())
        menu.addItem(TaskManagerMenuItem("刷新", action: monitor.updateData))
        menu.addItem(TaskManagerMenuItem("复制 PID", enabled: selectedProcess != nil, action: copyPID))
        menu.addItem(TaskManagerMenuItem("复制进程名", enabled: selectedProcess != nil, action: copyName))
        return menu
    }

    private func toggleGrouping() {
        state.frozenProcessOrder = nil
        state.groupProcessesByType.toggle()
    }

    private func expandAll() {
        state.expandedProcessIDs = Set(monitor.processes
            .filter { !$0.isApp && $0.parentPID > 1 }.map(\.parentPID))
    }

    private func collapseAll() { state.expandedProcessIDs.removeAll() }

    private func copyPID() {
        guard let process = selectedProcess else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(process.pid), forType: .string)
    }

    private func copyName() {
        guard let process = selectedProcess else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(process.name, forType: .string)
    }
}
