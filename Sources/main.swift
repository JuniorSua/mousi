import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var enabledItem: NSMenuItem!
    private var accessibilityItem: NSMenuItem!
    private let monitor = SelectionMonitor()
    private var pill: PillController!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // End-to-end self-test against a real app (see SelfTest.swift).
        if ProcessInfo.processInfo.environment["MOUSI_DEBUG_SELFTEST"] != nil {
            Task { @MainActor in await SelfTest.run() }
            return
        }

        pill = PillController()
        setupStatusItem()

        // Debug hook: show the real glass panel on screen in a given state (MOUSI_DEBUG_SHOW=compact|results|prompt|loading|error).
        if let state = ProcessInfo.processInfo.environment["MOUSI_DEBUG_SHOW"] {
            pill.debugShow(state: state)
            return
        }

        monitor.onSelection = { [weak self] text, point, target in
            guard let self, Settings.enabled else { return }
            self.pill.show(text: text, at: point, target: target)
        }
        monitor.onDismiss = { [weak self] in self?.pill.hide() }
        applyEnabledState()

        Accessibility.requestIfNeeded()
        if !Accessibility.isTrusted {
            // First run: the system prompt explains itself; open Settings so the API key can be added too.
            openSettings()
        }
        // Re-check permission periodically so a grant takes effect without a relaunch.
        var wasTrusted = Accessibility.isTrusted
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let trusted = Accessibility.isTrusted
                if trusted != wasTrusted {
                    wasTrusted = trusted
                    self.applyEnabledState() // re-arms the global event monitors
                }
                self.refreshMenuState()
            }
        }
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "cursorarrow.and.square.on.square.dashed", accessibilityDescription: "Mousi")
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            button.image = img?.withSymbolConfiguration(cfg)
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        let title = NSMenuItem(title: "Mousi", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        menu.addItem(enabledItem)

        accessibilityItem = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(openAccessibility), keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Mousi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
        refreshMenuState()
    }

    private func refreshMenuState() {
        enabledItem.state = Settings.enabled ? .on : .off
        let trusted = Accessibility.isTrusted
        accessibilityItem.isHidden = trusted
        statusItem.button?.appearsDisabled = !Settings.enabled
        statusItem.button?.toolTip = trusted
            ? (Settings.enabled ? "Mousi is on — highlight text to see the pill" : "Mousi is paused")
            : "Mousi needs Accessibility access"
    }

    private func applyEnabledState() {
        if Settings.enabled { monitor.start() } else { monitor.stop(); pill.hide() }
        refreshMenuState()
    }

    @objc private func toggleEnabled() {
        Settings.enabled.toggle()
        applyEnabledState()
    }

    @objc private func openAccessibility() {
        Accessibility.requestIfNeeded()
        Accessibility.openSystemSettings()
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView { [weak self] in self?.applyEnabledState() }
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "Mousi Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Entry point

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
    app.run()
}
