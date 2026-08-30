import AppKit
import Sparkle
import SwiftUI
import TownDockCore

@main
struct TownDockApp: App {
    @NSApplicationDelegateAdaptor(TownDockAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class TownDockAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = TownStore.shared
    private let statusItem = NSStatusBar.system.statusItem(
        withLength: NSStatusItem.variableLength
    )
    private let popover = NSPopover()
    private var dashboardWindow: NSWindow?
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private var updatesConfigured: Bool {
        guard
            let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        else { return false }
        return feedURL.hasPrefix("https://") && !publicKey.isEmpty
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        configureStatusItem()
        configurePopover()
        updateStatusItem()
        store.startPolling()
        if updatesConfigured {
            updaterController.startUpdater()
        }
        showDashboard()
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showDashboard()
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === dashboardWindow else { return true }
        sender.orderOut(nil)
        return false
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Town Sheriff"
        button.title = ""
        button.imageScaling = .scaleProportionallyDown
        button.setAccessibilityLabel("Town Sheriff")
        statusItem.isVisible = true
    }

    private func configurePopover() {
        popover.behavior = .transient
        // NSPopover's default zoom/slide transition stutters when hosting a
        // live SwiftUI hierarchy. An immediate toggle feels materially more
        // responsive and avoids exposing intermediate layout frames.
        popover.animates = false
        popover.contentSize = NSSize(width: 370, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(
                showDashboardAction: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.showDashboard()
                },
                checkForUpdatesAction: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.checkForUpdates()
                },
                updatesEnabled: updatesConfigured
            )
            .environmentObject(store)
        )
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = TownSheriffIcon.menuBarImage()
    }

    private func checkForUpdates() {
        guard updatesConfigured else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Updates aren’t configured in this build"
            alert.informativeText = "This is a local development build of Town Sheriff. Automatic updates become available in Developer ID-signed releases published with an update feed."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        updaterController.checkForUpdates(nil)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(
                relativeTo: sender.bounds,
                of: sender,
                preferredEdge: .minY
            )
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showDashboard() {
        if dashboardWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1_120, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Town Sheriff"
            window.minSize = NSSize(width: 920, height: 620)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .visible
            window.styleMask.insert(.fullSizeContentView)
            window.toolbarStyle = .unifiedCompact
            window.center()
            window.contentViewController = NSHostingController(
                rootView: DashboardView()
                    .environmentObject(store)
                    .frame(minWidth: 920, minHeight: 620)
            )
            dashboardWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        dashboardWindow?.makeKeyAndOrderFront(nil)
    }
}
