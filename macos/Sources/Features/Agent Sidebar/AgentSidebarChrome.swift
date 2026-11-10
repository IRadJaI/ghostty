import AppKit
import SwiftUI

// Fork addition (agent-sidebar): AppKit pieces of the sidebar that SwiftUI
// cannot express reliably: the backdrop strip in the titlebar and the
// resize handle.

/// Continues the sidebar backdrop into the window's titlebar, so the sidebar
/// runs the full height of the window like Finder's.
///
/// The titlebar view paints its own background over the content view, so
/// the strip has to live inside it, below the window buttons and the title.
@MainActor
enum AgentSidebarTitlebarBackdrop {
    private static let identifier = NSUserInterfaceItemIdentifier("AgentSidebarTitlebarBackdrop")

    /// Shows the strip at `width`, or removes it when `width` is nil.
    static func sync(window: NSWindow, width: CGFloat?) {
        let container = (window as? TerminalWindow)?.titlebarContainer?
            .firstDescendant(withClassName: "NSTitlebarView")
        let existing = container?.subviews.first { $0.identifier == identifier }

        guard let container, let width,
              !window.styleMask.contains(.fullScreen),
              container.bounds.height > 0
        else {
            existing?.removeFromSuperview()
            return
        }

        let frame = NSRect(x: 0, y: 0, width: width, height: container.bounds.height)
        if let existing {
            if existing.frame != frame {
                existing.frame = frame
            }
            return
        }

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

/// A tooltip backed by AppKit: SwiftUI's `.help` does not show up inside the
/// terminal window.
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
