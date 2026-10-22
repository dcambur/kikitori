import AppKit
import SwiftUI

/// The floating subtitle panel (spec §3): never key, on every Space, above full-screen video.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayController {
    static let shared = OverlayController()
    private var panel: OverlayPanel?
    private let model = AppModel.shared

    func setUp() {
        guard panel == nil else { return }
        let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 140),
                                 styleMask: [.nonactivatingPanel, .borderless, .resizable],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.minSize = NSSize(width: 360, height: 60)
        let host = NSHostingView(rootView: OverlayView().environment(model))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        self.panel = panel
        place()
        observe()
    }

    /// Show or hide following preferences and session state, and apply click-through.
    private func observe() {
        withObservationTracking {
            _ = model.prefs.overlayVisible
            _ = model.prefs.clickThrough
            _ = model.prefs.position
            _ = model.state
        } onChange: {
            Task { @MainActor in self.apply(); self.observe() }
        }
        apply()
    }

    private func apply() {
        guard let panel else { return }
        panel.ignoresMouseEvents = model.prefs.clickThrough
        let show = model.prefs.overlayVisible && model.state != .idle
        if show && !panel.isVisible { place(); panel.orderFrontRegardless() }
        if !show && panel.isVisible { panel.orderOut(nil) }
    }

    func place() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let x: CGFloat, y: CGFloat
        switch model.prefs.position {
        case .topLeft, .bottomLeft: x = frame.minX + 40
        case .topRight, .bottomRight: x = frame.maxX - size.width - 40
        default: x = frame.midX - size.width / 2
        }
        switch model.prefs.position {
        case .topLeft, .topCenter, .topRight: y = frame.maxY - size.height - 40
        default: y = frame.minY + 64
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func toggle() { model.prefs.overlayVisible.toggle() }
}
