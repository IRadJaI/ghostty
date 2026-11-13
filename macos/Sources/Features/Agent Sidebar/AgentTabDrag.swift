import SwiftUI
import UniformTypeIdentifiers

/// What is being dragged in the sidebar and the tab it hovers over.
struct AgentTabDragState: Equatable {
    var dragged: ObjectIdentifier?
    var target: ObjectIdentifier?
}

/// Lets a tab be dragged onto another tab of its window to take its place.
struct AgentTabDrag: ViewModifier {
    static let prefix = "ghostty-agent-tab:"

    let tab: AgentSidebarModel.Tab
    @Binding var state: AgentTabDragState

    func body(content: Content) -> some View {
        content
            .overlay(alignment: movesDown ? .bottom : .top) {
                if state.target == tab.id, state.dragged != tab.id {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                        .offset(y: movesDown ? 2 : -2)
                }
            }
            .onDrag {
                state.dragged = tab.id
                return NSItemProvider(object: (Self.prefix + tab.stableID) as NSString)
            }
            .onDrop(of: [UTType.plainText], delegate: Delegate(tab: tab, state: $state, after: movesDown))
    }

    /// A tab dragged from above lands after this one, from below — before it.
    private var movesDown: Bool {
        let tabs = AgentSidebarModel.shared.tabs
        guard let from = tabs.firstIndex(where: { $0.id == state.dragged }),
              let to = tabs.firstIndex(where: { $0.id == tab.id })
        else { return false }
        return from < to
    }

    private struct Delegate: DropDelegate {
        let tab: AgentSidebarModel.Tab
        @Binding var state: AgentTabDragState
        let after: Bool

        func validateDrop(info: DropInfo) -> Bool {
            state.dragged != nil
        }

        func dropEntered(info: DropInfo) {
            state.target = tab.id
        }

        func dropExited(info: DropInfo) {
            if state.target == tab.id {
                state.target = nil
            }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            DropProposal(operation: .move)
        }

        func performDrop(info: DropInfo) -> Bool {
            state = AgentTabDragState()
            guard let provider = info.itemProviders(for: [UTType.plainText]).first else { return false }
            let target = tab
            let after = after
            _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                guard let text = text as? String, text.hasPrefix(AgentTabDrag.prefix) else { return }
                let id = String(text.dropFirst(AgentTabDrag.prefix.count))
                DispatchQueue.main.async {
                    let model = AgentSidebarModel.shared
                    guard let dragged = model.tabs.first(where: { $0.stableID == id }) else { return }
                    model.move(dragged, to: target, after: after)
                }
            }
            return true
        }
    }
}
