import AppKit
import SwiftUI

@main
struct FirewallaDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = Store.shared

    var body: some Scene {
        Window("Firewalla", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 860, minHeight: 560)
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await store.refresh() } }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in Store.shared.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // stay in the Dock and keep updating the badge
    }

    /// Menu shown when right-clicking the Dock icon.
    @MainActor
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let store = Store.shared
        let menu = NSMenu()

        func info(_ title: String, _ symbol: String? = nil) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(item)
        }

        if !store.isConfigured {
            info("Not configured: open Settings")
            return menu
        }

        for box in store.boxes {
            info("\(box.name) · \(box.online ? "online" : "OFFLINE")", box.online ? "checkmark.circle" : "xmark.octagon")
        }
        if !store.boxes.isEmpty { menu.addItem(.separator()) }

        info("Active alarms: \(store.activeAlarms.count)", "bell")
        info("Devices online: \(store.onlineDevices)/\(store.devices.count)", "laptopcomputer.and.iphone")

        let recent = store.activeAlarms.prefix(5)
        if !recent.isEmpty {
            menu.addItem(.separator())
            info("Recent alarms")
            for a in recent {
                let title = a.message.count > 60 ? String(a.message.prefix(57)) + "…" : a.message
                info(title, AlarmType.icon(a.type))
            }
        }

        if let last = store.lastUpdated {
            menu.addItem(.separator())
            info("Updated \(Fmt.relative(last))")
        }

        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        return menu
    }

    @objc func refreshNow() {
        Task { @MainActor in await Store.shared.refresh() }
    }
}
