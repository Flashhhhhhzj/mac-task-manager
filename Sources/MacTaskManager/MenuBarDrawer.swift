import AppKit
import SwiftUI
import QuartzCore

private enum MenuBarDrawerLayout {
    static let width: CGFloat = 338
    static let height: CGFloat = 480
    static let arrowHeight: CGFloat = 10
    static let sidePadding: CGFloat = 24
    static let bottomPadding: CGFloat = 28
}

private struct MenuBarDrawerOutline: Shape {
    let arrowX: CGFloat

    func path(in rect: CGRect) -> Path {
        let top = rect.minY + MenuBarDrawerLayout.arrowHeight
        let radius: CGFloat = 10
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: top))
        path.addLine(to: CGPoint(x: arrowX - 12, y: top))
        path.addCurve(to: CGPoint(x: arrowX, y: rect.minY),
                      control1: CGPoint(x: arrowX - 6, y: top),
                      control2: CGPoint(x: arrowX - 5, y: rect.minY))
        path.addCurve(to: CGPoint(x: arrowX + 12, y: top),
                      control1: CGPoint(x: arrowX + 5, y: rect.minY),
                      control2: CGPoint(x: arrowX + 6, y: top))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: top + radius),
                          control: CGPoint(x: rect.maxX, y: top))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: top + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: top),
                          control: CGPoint(x: rect.minX, y: top))
        path.closeSubpath()
        return path
    }
}

private struct MenuBarDrawerSurface: View {
    let monitor: SystemMonitor
    let arrowX: CGFloat
    let bodyHeight: CGFloat
    @AppStorage(AppTheme.preferenceKey) private var appTheme = AppTheme.system.rawValue

    var body: some View {
        VStack(spacing: 0) {
            TaskManagerStyle.headerCell.frame(height: MenuBarDrawerLayout.arrowHeight)
            RunningApplicationsPopover(monitor: monitor, popoverHeight: bodyHeight)
        }
        .clipShape(MenuBarDrawerOutline(arrowX: arrowX))
        .shadow(color: .black.opacity(0.24), radius: 12, x: 0, y: 4)
        .padding(.horizontal, MenuBarDrawerLayout.sidePadding)
        .padding(.bottom, MenuBarDrawerLayout.bottomPadding)
        .preferredColorScheme((AppTheme(rawValue: appTheme) ?? .system).preferredColorScheme)
    }
}

private final class MenuBarDrawerPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
final class MenuBarStatusController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: 24)
    private let panel = MenuBarDrawerPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false
    )
    private let slidingView = NSView(frame: .zero)
    private let surface: NSHostingView<MenuBarDrawerSurface>
    private var isOpen = false
    private var animationID: UUID?
    private var outsideClickMonitors: [Any] = []
    private var contentFrame = NSRect.zero

    init(monitor: SystemMonitor) {
        surface = NSHostingView(rootView: MenuBarDrawerSurface(
            monitor: monitor, arrowX: MenuBarDrawerLayout.width / 2,
            bodyHeight: MenuBarDrawerLayout.height
        ))
        super.init()

        // Avoid restoring a previously hidden/overflow status-item placement.
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.appearance = nil
            let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium, scale: .medium)
            let image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "正在运行的应用")?
                .withSymbolConfiguration(configuration)
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.toolTip = "正在运行的应用"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        panel.title = "正在运行的应用"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The shadow is part of the moving SwiftUI surface throughout the animation.
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.onCancel = { [weak self] in self?.slideDrawer(opening: false) }

        let clipView = NSView(frame: .zero)
        clipView.wantsLayer = true
        clipView.layer?.masksToBounds = true
        panel.contentView = clipView
        slidingView.wantsLayer = true
        clipView.addSubview(slidingView)
        slidingView.addSubview(surface)
    }

    func reassertVisibility() {
        statusItem.isVisible = true
    }

    func invalidate() {
        animationID = nil
        isOpen = false
        panel.orderOut(nil)
        slidingView.layer?.removeAnimation(forKey: "drawerSlide")
        stopMonitoringOutsideClicks()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func togglePopover(_ sender: Any?) {
        if panel.isVisible {
            slideDrawer(opening: !isOpen)
        } else {
            showDrawer()
        }
    }

    private func showDrawer() {
        guard let button = statusItem.button, let anchorWindow = button.window,
              let screen = anchorWindow.screen else { return }
        let anchor = anchorWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let top = anchorWindow.frame.minY
        let bodyHeight = min(MenuBarDrawerLayout.height,
                             top - screen.visibleFrame.minY - MenuBarDrawerLayout.arrowHeight - MenuBarDrawerLayout.bottomPadding)
        guard bodyHeight > 0 else { return }
        let size = NSSize(width: MenuBarDrawerLayout.width + MenuBarDrawerLayout.sidePadding * 2,
                          height: bodyHeight + MenuBarDrawerLayout.arrowHeight + MenuBarDrawerLayout.bottomPadding)
        let x = min(max(anchor.midX - size.width / 2, screen.visibleFrame.minX), screen.visibleFrame.maxX - size.width)
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: false)
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
        slidingView.frame = NSRect(origin: .zero, size: size)
        surface.frame = slidingView.bounds
        let arrowX = min(max(anchor.midX - x - MenuBarDrawerLayout.sidePadding, 24), MenuBarDrawerLayout.width - 24)
        surface.rootView = MenuBarDrawerSurface(monitor: surface.rootView.monitor, arrowX: arrowX, bodyHeight: bodyHeight)
        contentFrame = NSRect(x: x + MenuBarDrawerLayout.sidePadding,
                              y: panel.frame.minY + MenuBarDrawerLayout.bottomPadding,
                              width: MenuBarDrawerLayout.width,
                              height: bodyHeight + MenuBarDrawerLayout.arrowHeight)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        slidingView.layer?.transform = hiddenTransform
        CATransaction.commit()
        surface.layoutSubtreeIfNeeded()
        slideDrawer(opening: true)
        panel.makeKeyAndOrderFront(nil)
        startMonitoringOutsideClicks()
    }

    private var hiddenTransform: CATransform3D {
        CATransform3DMakeTranslation(0, slidingView.isFlipped ? -slidingView.bounds.height : slidingView.bounds.height, 0)
    }

    private func slideDrawer(opening: Bool) {
        guard let layer = slidingView.layer else { return }
        let start = animationID == nil ? layer.transform : (layer.presentation()?.transform ?? layer.transform)
        let target = opening ? CATransform3DIdentity : hiddenTransform
        let token = UUID()
        animationID = token
        isOpen = opening
        statusItem.button?.state = opening ? .on : .off
        let distance = min(1, abs(target.m42 - start.m42) / max(1, slidingView.bounds.height))
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: start)
        animation.toValue = NSValue(caTransform3D: target)
        animation.duration = (opening ? 0.36 : 0.24) * max(0.15, distance)
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.25, 1)

        let finish = { [weak self] in
            guard let self, self.animationID == token else { return }
            self.animationID = nil
            if !opening {
                self.panel.orderOut(nil)
                self.stopMonitoringOutsideClicks()
            }
            // Keep the final model transform, including the hidden position after closing.
            self.slidingView.layer?.removeAnimation(forKey: "drawerSlide")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "drawerSlide")
        layer.transform = target
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            CATransaction.commit()
            finish()
        } else {
            CATransaction.setCompletionBlock(finish)
            layer.add(animation, forKey: "drawerSlide")
            CATransaction.commit()
        }
    }

    private func startMonitoringOutsideClicks() {
        stopMonitoringOutsideClicks()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let interactions = clicks.union([.leftMouseUp, .rightMouseUp, .otherMouseUp, .scrollWheel])
        if let local = NSEvent.addLocalMonitorForEvents(matching: interactions, handler: { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
                let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
                self.closeDrawerIfClickedOutside(at: point)
            }
            // A moving row must not receive a click meant for its presentation position.
            return event.window === self.panel && self.animationID != nil ? nil : event
        }) {
            outsideClickMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            self?.closeDrawerIfClickedOutside(at: NSEvent.mouseLocation)
        }) {
            outsideClickMonitors.append(global)
        }
    }

    private func closeDrawerIfClickedOutside(at point: NSPoint) {
        guard panel.isVisible, isOpen, !contentFrame.contains(point) else { return }
        if let button = statusItem.button, let anchorWindow = button.window,
           anchorWindow.convertToScreen(button.convert(button.bounds, to: nil)).contains(point) {
            return
        }
        slideDrawer(opening: false)
    }

    private func stopMonitoringOutsideClicks() {
        outsideClickMonitors.forEach(NSEvent.removeMonitor)
        outsideClickMonitors.removeAll()
    }
}
