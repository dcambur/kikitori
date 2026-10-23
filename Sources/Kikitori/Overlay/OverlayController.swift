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
    /// The stress test keeps the panel far off any screen.
    var offscreen = false

    func setUp() {
        guard panel == nil else { return }
        let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 140),
                                 styleMask: [.nonactivatingPanel, .borderless],
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
        // The panel must not size itself from the view (`.intrinsicContentSize`): subtitle text
        // wraps by width, so window size and content size chase each other until AppKit throws
        // "more Update Constraints passes than views". The view reports its natural size instead,
        // and the panel is resized once, outside the layout pass.
        let root = OverlayView()
            .fixedSize()
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                DispatchQueue.main.async { OverlayController.shared.fit(size) }
            }
            .environment(model)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
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
            _ = model.source
            if model.source?.id == PlayerController.sourceID { _ = PlayerController.shared.isOnScreen }
        } onChange: {
            Task { @MainActor in self.apply(); self.observe() }
        }
        apply()
    }

    private func apply() {
        guard let panel else { return }
        panel.ignoresMouseEvents = model.prefs.clickThrough
        // The built-in player draws subtitles on the video itself; the floating panel is for other
        // apps, and for the player while its video is off screen (another section, window closed).
        let playerShowsThem = model.source?.id == PlayerController.sourceID && PlayerController.shared.isOnScreen
        let show = model.prefs.overlayVisible && model.state != .idle && !playerShowsThem
        if show && !panel.isVisible { place(); panel.orderFrontRegardless() }
        if !show && panel.isVisible { panel.orderOut(nil) }
    }

    func place() {
        guard let panel, let screen = NSScreen.main else { return }
        if offscreen { panel.setFrameOrigin(NSPoint(x: -6000, y: -6000)); return }
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

    /// Resize to the subtitles' natural size, keeping the edge the panel is anchored to in place
    /// (bottom presets keep the bottom edge, top presets the top; left, centre or right likewise).
    func fit(_ size: CGSize) {
        guard let panel, size.width > 1, size.height > 1 else { return }
        let old = panel.frame
        guard abs(old.width - size.width) > 0.5 || abs(old.height - size.height) > 0.5 else { return }
        let position = model.prefs.position
        let x: CGFloat = switch position {
        case .topLeft, .bottomLeft: old.minX
        case .topRight, .bottomRight: old.maxX - size.width
        default: old.midX - size.width / 2
        }
        let y: CGFloat = switch position {
        case .topLeft, .topCenter, .topRight: old.maxY - size.height
        default: old.minY
        }
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    func toggle() { model.prefs.overlayVisible.toggle() }
}
