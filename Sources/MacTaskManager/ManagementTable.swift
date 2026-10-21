import SwiftUI
import AppKit

struct ManagementColumn {
    let id: String
    let title: String
    let width: CGFloat
    var numeric = false
    var sortable = true
    var summary: String?
}

struct ManagementCell: Equatable {
    var text: String
    var number: Double?
    var heat: Double?
    var muted = false
    var icon: NSImage?
    var tooltip: String?
}

struct ManagementRow: Equatable, Identifiable {
    let id: String
    var cells: [String: ManagementCell]
    var level = 0
    var expandable = false
    var expanded = false
}

struct ManagementMenuAction {
    let title: String
    var icon: String?
    var enabled = true
    let action: () -> Void
}

enum ManagementFormatting {
    static func memory(_ bytes: UInt64) -> String {
        let value = Double(bytes) / 1_048_576
        return value >= 1024 ? String(format: "%.1f GB", value / 1024) : String(format: "%.1f MB", value)
    }
    static func bytes(_ value: UInt64) -> String {
        if value >= 1_073_741_824 { return String(format: "%.1f GB", Double(value) / 1_073_741_824) }
        if value >= 1_048_576 { return String(format: "%.1f MB", Double(value) / 1_048_576) }
        return String(format: "%.1f KB", Double(value) / 1024)
    }
    static func cpu(_ value: Double) -> String { value < 0.05 ? "0%" : String(format: "%.1f%%", value) }
    static func disk(_ value: Double) -> String { value < 524 ? "0 MB/秒" : String(format: "%.1f MB/秒", value / 1_048_576) }
    static func network(_ value: Double) -> String { value < 6250 ? "0 Mbps" : String(format: "%.1f Mbps", value * 8 / 1_000_000) }
    static func duration(_ value: UInt64) -> String {
        let seconds = value / 1_000_000_000
        return String(format: "%llu:%02llu:%02llu", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    static func sorted(_ rows: [ManagementRow], state: ManagementTableState, columns: [ManagementColumn]) -> [ManagementRow] {
        guard let column = columns.first(where: { $0.id == state.sortColumn }) else { return rows }
        return rows.sorted { left, right in
            let a = left.cells[column.id], b = right.cells[column.id]
            if column.numeric {
                if a?.number == nil && b?.number != nil { return false }
                if a?.number != nil && b?.number == nil { return true }
                if let av = a?.number, let bv = b?.number, av != bv { return state.ascending ? av < bv : av > bv }
            } else {
                let comparison = (a?.text ?? "").localizedStandardCompare(b?.text ?? "")
                if comparison != .orderedSame { return state.ascending ? comparison == .orderedAscending : comparison == .orderedDescending }
            }
            let names = (left.cells["name"]?.text ?? "").localizedStandardCompare(right.cells["name"]?.text ?? "")
            return names == .orderedSame ? left.id < right.id : names == .orderedAscending
        }
    }
}

struct ManagementNativeTable: NSViewRepresentable {
    let columns: [ManagementColumn]
    let rows: [ManagementRow]
    @ObservedObject var state: ManagementTableState
    let rowHeight = TaskManagerStyle.tableRowHeight
    let headerHeight = TaskManagerStyle.tableHeaderHeight
    var onDoubleClick: (String) -> Void = { _ in }
    var onToggle: (String) -> Void = { _ in }
    var menu: (String) -> [ManagementMenuAction] = { _ in [] }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.drawsBackground = true; scroll.backgroundColor = NSColor(TaskManagerStyle.surface)
        let table = ManagementNSTableView()
        table.style = .plain
        table.headerView = ManagementHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: headerHeight))
        table.dataSource = context.coordinator; table.delegate = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.doubleClick(_:))
        table.rowHeight = rowHeight; table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.backgroundColor = NSColor(TaskManagerStyle.surface)
        table.usesAlternatingRowBackgroundColors = false
        table.columnAutoresizingStyle = columns.count == 3 && columns.last?.id == "description" ? .lastColumnOnlyAutoresizingStyle : .noColumnAutoresizing
        table.allowsColumnReordering = true
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.setAccessibilityLabel("管理列表")
        for spec in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.width = state.columnWidths[spec.id] ?? spec.width
            column.minWidth = columns.count == 3 && spec.id == "description" ? 500 : min(spec.width, spec.numeric ? 54 : 70)
            column.maxWidth = 1600
            column.resizingMask = columns.count == 3 && spec.id == "description" ? [.userResizingMask, .autoresizingMask] : .userResizingMask
            column.headerCell = ManagementHeaderCell(textCell: spec.title)
            table.addTableColumn(column)
        }
        table.menuProvider = { [weak coordinator = context.coordinator] row in coordinator?.contextMenu(row) }
        scroll.documentView = table
        context.coordinator.table = table
        context.coordinator.scroll = scroll
        updateNSView(scroll, context: context)
        DispatchQueue.main.async {
            scroll.contentView.scroll(to: state.scrollOrigin ?? NSPoint(x: 0, y: -headerHeight))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let table = scroll.documentView as? NSTableView else { return }
        table.backgroundColor = NSColor(TaskManagerStyle.surface)
        scroll.backgroundColor = NSColor(TaskManagerStyle.surface)
        table.rowHeight = rowHeight
        table.headerView?.frame.size.height = headerHeight
        for column in table.tableColumns {
            if let spec = columns.first(where: { $0.id == column.identifier.rawValue }), let cell = column.headerCell as? ManagementHeaderCell {
                cell.summary = spec.summary
                cell.nameColumn = spec.id == "name"
                cell.numeric = spec.numeric && spec.id != "status"
                cell.selected = state.sortColumn == spec.id && spec.sortable
                cell.arrowDown = state.ascending == !spec.numeric
            }
        }
        table.headerView?.needsDisplay = true
        let old = coordinator.rows
        let origin = scroll.contentView.bounds.origin
        coordinator.rows = rows
        coordinator.updating = true
        if old.map(\.id) != rows.map(\.id) {
            let difference = rows.map(\.id).difference(from: old.map(\.id))
            var removed = IndexSet(), inserted = IndexSet()
            for change in difference {
                switch change {
                case .remove(let index, _, _): removed.insert(index)
                case .insert(let index, _, _): inserted.insert(index)
                }
            }
            table.beginUpdates()
            table.removeRows(at: removed, withAnimation: [])
            table.insertRows(at: inserted, withAnimation: [])
            table.endUpdates()
            let changed = IndexSet(rows.indices.filter { !inserted.contains($0) })
            table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integersIn: 0..<columns.count))
        } else {
            let changed = IndexSet(rows.indices.filter { old[$0] != rows[$0] })
            if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integersIn: 0..<columns.count)) }
        }
        if let selected = state.selectedID, let index = rows.firstIndex(where: { $0.id == selected }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
            if let stale = state.selectedID {
                DispatchQueue.main.async { if state.selectedID == stale { state.selectedID = nil } }
            }
        }
        coordinator.updating = false
        scroll.contentView.scroll(to: NSPoint(x: origin.x, y: min(origin.y, max(0, table.bounds.height - scroll.contentView.bounds.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.parent.state.scrollOrigin = scroll.contentView.bounds.origin
        if let table = scroll.documentView as? NSTableView {
            for column in table.tableColumns { coordinator.parent.state.columnWidths[column.identifier.rawValue] = column.width }
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ManagementNativeTable
        var rows: [ManagementRow] = []
        var updating = false
        weak var table: NSTableView?
        weak var scroll: NSScrollView?
        private var menuActions: [ManagementMenuAction] = []
        init(_ parent: ManagementNativeTable) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
            guard rows.indices.contains(index), let tableColumn else { return nil }
            let column = tableColumn.identifier.rawValue
            let view = (tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? ManagementCellView) ?? ManagementCellView()
            view.identifier = tableColumn.identifier
            let row = rows[index]
            view.configure(row.cells[column] ?? ManagementCell(text: ""), nameColumn: column == "name", numeric: column != "status" && parent.columns.first(where: { $0.id == column })?.numeric == true,
                           level: column == "name" ? row.level : 0, expandable: column == "name" && row.expandable, expanded: row.expanded)
            view.toggle = { [weak self] in self?.parent.onToggle(row.id) }
            return view
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ManagementRowView() }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            parent.state.selectedID = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
            table.enumerateAvailableRowViews { view, _ in view.needsDisplay = true; view.subviews.forEach { $0.needsDisplay = true } }
        }
        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let spec = parent.columns.first(where: { $0.id == tableColumn.identifier.rawValue }), spec.sortable else { return }
            parent.state.sort(spec.id, numeric: spec.numeric)
        }
        func tableViewColumnDidResize(_ notification: Notification) {
            guard let table else { return }
            for column in table.tableColumns { parent.state.columnWidths[column.identifier.rawValue] = column.width }
        }
        @objc func doubleClick(_ sender: NSTableView) {
            guard rows.indices.contains(sender.clickedRow) else { return }
            parent.onDoubleClick(rows[sender.clickedRow].id)
        }
        func contextMenu(_ row: Int) -> NSMenu? {
            guard rows.indices.contains(row) else { return nil }
            table?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            menuActions = parent.menu(rows[row].id)
            let menu = NSMenu()
            menu.autoenablesItems = false
            for (index, action) in menuActions.enumerated() {
                let item = NSMenuItem(title: action.title, action: #selector(invokeMenu(_:)), keyEquivalent: "")
                item.target = self; item.tag = index; item.isEnabled = action.enabled
                if let icon = action.icon { item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil) }
                menu.addItem(item)
            }
            return menu
        }
        @objc private func invokeMenu(_ item: NSMenuItem) {
            if menuActions.indices.contains(item.tag), menuActions[item.tag].enabled { menuActions[item.tag].action() }
        }
    }
}

private final class ManagementNSTableView: NSTableView {
    var menuProvider: ((Int) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?(row(at: convert(event.locationInWindow, from: nil))) }
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { super.rightMouseDown(with: event); return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

private final class ManagementHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(TaskManagerStyle.surface).setFill(); dirtyRect.fill()
        guard let tableView else { return }
        for (index, column) in tableView.tableColumns.enumerated() {
            column.headerCell.draw(withFrame: headerRect(ofColumn: index), in: self)
        }
    }
}

private final class ManagementHeaderCell: NSTableHeaderCell {
    var selected = false
    var nameColumn = false
    var numeric = false
    var arrowDown = true
    var summary: String?
    override func draw(withFrame frame: NSRect, in controlView: NSView) {
        NSColor(selected ? TaskManagerStyle.selectedHeader : TaskManagerStyle.surface).setFill(); frame.fill()
        let textRect = frame.insetBy(dx: nameColumn ? 18 : 14, dy: 7)
        let style = NSMutableParagraphStyle()
        style.alignment = summary != nil ? .center : numeric ? .right : .left
        style.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize: TaskManagerStyle.tableHeaderFontSize)
        let labelHeight = ceil(font.ascender - font.descender + font.leading)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(TaskManagerStyle.muted), .paragraphStyle: style]
        let label = NSRect(x: textRect.minX, y: frame.maxY - 7 - labelHeight, width: textRect.width, height: labelHeight)
        (stringValue as NSString).draw(in: label, withAttributes: attributes)
        if let summary {
            let summaryFont = NSFont.systemFont(ofSize: TaskManagerStyle.tableSummaryFontSize)
            let summaryHeight = ceil(summaryFont.ascender - summaryFont.descender + summaryFont.leading)
            let top = NSRect(x: textRect.minX, y: label.minY - 3 - summaryHeight, width: textRect.width, height: summaryHeight)
            (summary as NSString).draw(in: top, withAttributes: [.font: summaryFont, .foregroundColor: NSColor(TaskManagerStyle.text), .paragraphStyle: style])
        }
        if selected {
            let path = NSBezierPath()
            let mid = frame.midX, y = frame.minY + 2
            path.move(to: NSPoint(x: mid - 4, y: y + (arrowDown ? 0 : 3)))
            path.line(to: NSPoint(x: mid, y: y + (arrowDown ? 3 : 0)))
            path.line(to: NSPoint(x: mid + 4, y: y + (arrowDown ? 0 : 3)))
            NSColor(TaskManagerStyle.muted).setStroke(); path.lineWidth = 1; path.stroke()
        }
        NSColor(TaskManagerStyle.grid).setFill()
        NSRect(x: frame.maxX - 1, y: frame.minY, width: 1, height: frame.height).fill()
        NSRect(x: frame.minX, y: frame.maxY - 1, width: frame.width, height: 1).fill()
    }
}

private final class ManagementRowView: NSTableRowView {
    private var hovering = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func drawBackground(in dirtyRect: NSRect) {
        NSColor(isSelected ? TaskManagerStyle.selectedSidebar : hovering ? TaskManagerStyle.selectedRow : TaskManagerStyle.surface).setFill()
        dirtyRect.fill()
    }
    override func drawSelection(in dirtyRect: NSRect) { drawBackground(in: dirtyRect) }
}

private final class ManagementCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let image = NSImageView()
    private let disclosure = NSButton()
    private var value = ManagementCell(text: "")
    private var numeric = false
    private var nameColumn = false
    private var level = 0
    private var expandable = false
    var toggle: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(label); addSubview(image); addSubview(disclosure)
        label.font = .systemFont(ofSize: TaskManagerStyle.tableBodyFontSize); label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1; label.isSelectable = false
        image.imageScaling = .scaleProportionallyUpOrDown
        disclosure.isBordered = false; disclosure.target = self; disclosure.action = #selector(toggleRow)
        disclosure.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ value: ManagementCell, nameColumn: Bool, numeric: Bool, level: Int, expandable: Bool, expanded: Bool) {
        self.value = value; self.nameColumn = nameColumn; self.numeric = numeric; self.level = level; self.expandable = expandable
        label.stringValue = value.text
        label.alignment = numeric ? .right : .left
        label.textColor = NSColor(value.muted ? TaskManagerStyle.muted : TaskManagerStyle.text)
        image.image = value.icon; image.isHidden = value.icon == nil
        disclosure.isHidden = !expandable
        disclosure.contentTintColor = NSColor(TaskManagerStyle.muted)
        disclosure.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: expanded ? "折叠" : "展开")
        toolTip = value.tooltip ?? value.text
        setAccessibilityLabel(value.text)
        needsLayout = true; needsDisplay = true
    }
    override func layout() {
        super.layout()
        let offset: CGFloat = isFlipped ? 2 : -2
        var left: CGFloat = numeric ? 0 : 14
        if nameColumn {
            left = 22 + CGFloat(level) * 22
            disclosure.frame = NSRect(x: left, y: (bounds.height - 24) / 2 + offset, width: 16, height: 24)
            left += 24
            let iconSize = TaskManagerStyle.tableIconSize
            image.frame = NSRect(x: left, y: (bounds.height - iconSize) / 2 + offset, width: iconSize, height: iconSize)
            left += iconSize + 8
        }
        label.frame = NSRect(x: left, y: (bounds.height - 22) / 2 + offset, width: max(0, bounds.width - left - 14), height: 22)
    }
    override func draw(_ dirtyRect: NSRect) {
        if let heat = value.heat {
            NSColor(heat > 0.72 ? TaskManagerStyle.resourceHot : TaskManagerStyle.resource).setFill(); bounds.fill()
            if (superview as? NSTableRowView)?.isSelected == true {
                NSColor.selectedControlColor.withAlphaComponent(0.1).setFill(); bounds.fill()
            }
        }
        NSColor(TaskManagerStyle.grid).setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
    }
    @objc private func toggleRow() { toggle?() }
}
