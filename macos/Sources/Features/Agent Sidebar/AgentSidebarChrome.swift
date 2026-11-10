import AppKit
import SwiftUI

// Fork addition (agent-sidebar): AppKit parts of the sidebar (titlebar strip, resize handle, tooltips).

/// Continues the sidebar backdrop into the window's titlebar, so the sidebar runs the full height of the window like Finder's.
@MainActor
enum AgentSidebarTitlebarBackdrop {
    private static let identifier = NSUserInterfaceItemIdentifier("AgentSidebarTitlebarBackdrop")
    private static let titleIdentifier = NSUserInterfaceItemIdentifier("AgentSidebarTitlebarTitle")

    /// Shows the strip at `width`, or removes it when `width` is nil.
    static func sync(window: NSWindow, width: CGFloat?) {
        let container = (window as? TerminalWindow)?.titlebarContainer?
            .firstDescendant(withClassName: "NSTitlebarView")
        let existing = container?.subviews.first { $0.identifier == identifier }
        let title = container?.subviews.first { $0.identifier == titleIdentifier } as? TitleLabel

        guard let container, let width,
              !window.styleMask.contains(.fullScreen),
              container.bounds.height > 0
        else {
            existing?.removeFromSuperview()
            if let title {
                title.removeFromSuperview()
                window.titleVisibility = .visible
            }
            return
        }

        let frame = NSRect(x: 0, y: 0, width: width, height: container.bounds.height)
        if let existing {
            if existing.frame != frame {
                existing.frame = frame
            }
        } else {
            let backdrop = NSVisualEffectView(frame: frame)
            backdrop.identifier = identifier
            backdrop.material = .sidebar
            backdrop.blendingMode = .behindWindow
            backdrop.state = .followsWindowActiveState
            backdrop.autoresizingMask = [.height]

            let separator = NSBox(frame: NSRect(x: width - 1, y: 0, width: 1, height: frame.height))
            separator.boxType = .separator
            separator.autoresizingMask = [.height, .minXMargin]
            backdrop.addSubview(separator)

            container.addSubview(backdrop, positioned: .below, relativeTo: nil)
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
        nsView.toolTip = text
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
