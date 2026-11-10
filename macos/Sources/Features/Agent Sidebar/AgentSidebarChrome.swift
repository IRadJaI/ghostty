import AppKit
import SwiftUI

// Fork addition (agent-sidebar): AppKit parts of the sidebar (titlebar strip, resize handle, tooltips).

/// Continues the sidebar backdrop into the window's titlebar, so the sidebar runs the full height of the window like Finder's.
@MainActor
enum AgentSidebarTitlebarBackdrop {
    private static let identifier = NSUserInterfaceItemIdentifier("AgentSidebarTitlebarBackdrop")
    private static let separatorIdentifier = NSUserInterfaceItemIdentifier("AgentSidebarTitlebarSeparator")
    private static let titleIdentifier = NSUserInterfaceItemIdentifier("AgentSidebarTitlebarTitle")

    /// Shows the strip at `width`, or removes it when `width` is nil.
    static func sync(window: NSWindow, width: CGFloat?, chrome: AgentSidebarModel.Chrome) {
        let container = (window as? TerminalWindow)?.titlebarContainer?
            .firstDescendant(withClassName: "NSTitlebarView")
        let existing = container?.subviews.first { $0.identifier == identifier }
        let separator = container?.subviews.first { $0.identifier == separatorIdentifier }
        let title = container?.subviews.first { $0.identifier == titleIdentifier } as? TitleLabel

        guard let container, let width,
              !window.styleMask.contains(.fullScreen),
              container.bounds.height > 0
        else {
            existing?.removeFromSuperview()
            separator?.removeFromSuperview()
            if let title {
                title.removeFromSuperview()
                window.titleVisibility = .visible
            }
            return
        }

        let frame = NSRect(x: 0, y: 0, width: width, height: container.bounds.height)
        let backdrop = existing ?? {
            let backdrop = NSVisualEffectView(frame: frame)
            backdrop.identifier = identifier
            backdrop.material = .sidebar
            backdrop.blendingMode = .behindWindow
            backdrop.state = .followsWindowActiveState
            backdrop.autoresizingMask = [.height]
            container.addSubview(backdrop, positioned: .below, relativeTo: nil)
            return backdrop
        }()
        if backdrop.frame != frame {
            backdrop.frame = frame
        }
        // Without the material the titlebar's own background matches the sidebar.
        let hidden = chrome != .material
        if backdrop.isHidden != hidden {
            backdrop.isHidden = hidden
        }

        let line = separator ?? {
            let line = NSBox()
            line.identifier = separatorIdentifier
            line.boxType = .separator
            line.autoresizingMask = [.height]
            container.addSubview(line, positioned: .above, relativeTo: backdrop)
            return line
        }()
        let lineFrame = NSRect(x: width - 1, y: 0, width: 1, height: frame.height)
        if line.frame != lineFrame {
            line.frame = lineFrame
        }

        // Window styles that hide the title themselves keep it that way.
        guard title != nil || window.titleVisibility == .visible else { return }
        if window.titleVisibility != .hidden {
            window.titleVisibility = .hidden
        }
        let label = title ?? {
            let label = TitleLabel(labelWithString: "")
            label.identifier = titleIdentifier
            label.font = .titleBarFont(ofSize: NSFont.systemFontSize)
            label.lineBreakMode = .byTruncatingMiddle
            container.addSubview(label)
            return label
        }()
        if label.stringValue != window.title {
            label.stringValue = window.title
        }
        let color: NSColor = window.isKeyWindow ? .labelColor : .secondaryLabelColor
        if label.textColor != color {
            label.textColor = color
        }
        // Glass shows whatever is behind the window; keep the title legible.
        if chrome == .glass, label.shadow == nil {
            let shadow = NSShadow()
            let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            shadow.shadowColor = (dark ? NSColor.black : NSColor.white).withAlphaComponent(0.7)
            shadow.shadowBlurRadius = 3
            label.shadow = shadow
        } else if chrome != .glass, label.shadow != nil {
            label.shadow = nil
        }
        let height = label.intrinsicContentSize.height
        let inset: CGFloat = 12
        let labelFrame = NSRect(
            x: width + inset,
            y: ((container.bounds.height - height) / 2).rounded(),
            width: max(0, container.bounds.width - width - inset * 2),
            height: height)
        if label.frame != labelFrame {
            label.frame = labelFrame
        }
    }

    /// A title that leaves clicks to the titlebar (dragging, double click).
    private final class TitleLabel: NSTextField {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Whether the collapsed sidebar is widened. Shared: every tab is its own window.
@MainActor
final class AgentSidebarPeek: ObservableObject {
    static let shared = AgentSidebarPeek()

    @Published private(set) var open = false

    private var opening: DispatchWorkItem?
    private var watcher: Timer?

    /// Opens after a short delay, so a pointer crossing the rail does not.
    func pointerEntered() {
        guard !open, opening == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.opening = nil
            if self.pointerIsOverSidebar(width: AgentSidebarModel.collapsedWidth + 1) {
                self.setOpen(true)
            }
        }
        opening = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func close() {
        opening?.cancel()
        opening = nil
        setOpen(false)
    }

    private func setOpen(_ value: Bool) {
        guard open != value else { return }
        open = value
        watcher?.invalidate()
        watcher = nil
        guard value else { return }
        // Hover events do not survive a switch to another tab's window, so
        // the pointer is polled while the rail is open.
        var outside = 0
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.open else { return }
                let width = AgentSidebarModel.clampedWidth(
                    UserDefaults.standard.double(forKey: AgentSidebarDefaults.width))
                outside = self.pointerIsOverSidebar(width: width) ? 0 : outside + 1
                if outside >= 2 {
                    self.setOpen(false)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watcher = timer
    }

    private func pointerIsOverSidebar(width: CGFloat) -> Bool {
        guard NSApp.isActive,
              let window = NSApp.keyWindow, window.windowController is TerminalController,
              let content = window.contentView
        else { return false }
        // An open menu or a sheet keeps the rail as it is.
        if window.attachedSheet != nil || RunLoop.main.currentMode == .eventTracking { return true }
        let area = window.convertToScreen(content.convert(content.bounds, to: nil))
        let pointer = NSEvent.mouseLocation
        return pointer.x >= area.minX && pointer.x <= area.minX + width
            && pointer.y >= area.minY && pointer.y <= area.maxY
    }
}

/// An outline around the pane whose agent waits for the user.
@MainActor
enum AgentPaneRing {
    private static let identifier = NSUserInterfaceItemIdentifier("AgentPaneRing")

    static func sync(_ surface: NSView, show: Bool) {
        let existing = surface.subviews.first { $0.identifier == identifier }
        guard show else {
            existing?.removeFromSuperview()
            return
        }
        guard existing == nil else { return }
        let ring = RingView(frame: surface.bounds)
        ring.identifier = identifier
        ring.autoresizingMask = [.width, .height]
        ring.wantsLayer = true
        ring.layer?.borderWidth = 2
        ring.layer?.borderColor = NSColor.systemOrange.cgColor
        surface.addSubview(ring)
    }

    private final class RingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The sidebar's trailing edge: draws the divider and resizes on drag.
struct AgentSidebarResizeHandle: NSViewRepresentable {
    static let hitWidth: CGFloat = 7

    @Binding var width: Double

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.toolTip = "Drag to resize the sidebar"
        return view
    }

    func updateNSView(_ nsView: HandleView, context: Context) {
        let binding = $width
        nsView.currentWidth = { binding.wrappedValue }
        nsView.setWidth = { binding.wrappedValue = Double(AgentSidebarModel.clampedWidth($0)) }
    }

    final class HandleView: NSView {
        var currentWidth: () -> Double = { 0 }
        var setWidth: (Double) -> Void = { _ in }

        private var dragStart: (x: CGFloat, width: Double)?

        override var mouseDownCanMoveWindow: Bool { false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.separatorColor.setFill()
            NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        }

        override func mouseDown(with event: NSEvent) {
            dragStart = (event.locationInWindow.x, currentWidth())
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragStart else { return }
            setWidth(dragStart.width + Double(event.locationInWindow.x - dragStart.x))
        }

        override func mouseUp(with event: NSEvent) {
            dragStart = nil
        }
    }
}

/// A tooltip backed by AppKit.
private struct AgentTooltipView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> PassthroughView {
        PassthroughView()
    }

    func updateNSView(_ nsView: PassthroughView, context: Context) {
        nsView.toolTip = text.isEmpty ? nil : text
    }

    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    func agentTooltip(_ text: String) -> some View {
        overlay { AgentTooltipView(text: text) }
    }
}
