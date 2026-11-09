import AppKit

// Fork addition (agent-sidebar): main-menu items and keyboard shortcuts.
//
// The items are appended to the View menu at runtime so the fork does not
// have to edit MainMenu.xib.

/// Target of the sidebar's menu items. One instance lives for the whole app.
@MainActor
final class AgentSidebarMenu: NSObject, NSMenuItemValidation {
    static let shared = AgentSidebarMenu()

    private var installed = false

    /// Adds the sidebar items to the View menu once.
    func install() {
        guard !installed, let mainMenu = NSApp.mainMenu else { return }
        guard let menu = mainMenu.items.first(where: { $0.submenu?.title == "View" })?.submenu
            ?? mainMenu.items.first(where: { $0.submenu?.title == "Window" })?.submenu
        else { return }
        installed = true

        menu.addItem(.separator())
        menu.addItem(item("Show Tab Sidebar", #selector(toggleSidebar(_:)), key: "s"))
        menu.addItem(item("Show Agent Tabs Only", #selector(toggleAgentsOnly(_:)), key: "g"))
        menu.addItem(item("Go to Next Tab Needing Attention", #selector(nextAttention(_:)), key: "a"))
    }

    private func item(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = [.control, .command]
        item.target = self
        return item
    }

    @objc func toggleSidebar(_ sender: Any?) {
        toggle(AgentSidebarDefaults.visible)
    }

    @objc func toggleAgentsOnly(_ sender: Any?) {
        toggle(AgentSidebarDefaults.agentsOnly)
    }

    @objc func nextAttention(_ sender: Any?) {
        AgentSidebarModel.shared.selectNextNeedingAttention()
    }

    private func toggle(_ key: String) {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: key), forKey: key)
        AgentSidebarModel.shared.refresh()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let defaults = UserDefaults.standard
        switch menuItem.action {
        case #selector(toggleSidebar(_:)):
            menuItem.state = defaults.bool(forKey: AgentSidebarDefaults.visible) ? .on : .off
            return true
        case #selector(toggleAgentsOnly(_:)):
            menuItem.state = defaults.bool(forKey: AgentSidebarDefaults.agentsOnly) ? .on : .off
            return defaults.bool(forKey: AgentSidebarDefaults.visible)
        case #selector(nextAttention(_:)):
            return AgentSidebarModel.shared.tabs.contains { $0.needsAttention }
        default:
            return true
        }
    }
}
