import AppKit
import SwiftUI

@MainActor
final class PillController: ObservableObject {
    enum Phase: Equatable {
        case compact
        case working(String)          // label shown next to the spinner
        case done(String)             // "Replaced" / "Copied" / …
        case note(String, String)     // title, body — for actions that report instead of rewrite
        case error(String)
    }

    @Published var phase: Phase = .compact

    private(set) var text: String = ""
    private var target: SelectionTarget?
    private let panel: NSPanel
    private let hosting: NSHostingView<PillRootView>
    private var anchorTopLeft: NSPoint = .zero
    private var hideTask: Task<Void, Never>?
    private var workTask: Task<Void, Never>?

    var isVisible: Bool { panel.isVisible }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the SwiftUI view draws its own soft shadow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true

        hosting = NSHostingView(rootView: PillRootView(controller: nil))
        panel.contentView = hosting
        hosting.rootView = PillRootView(controller: self)
    }

    // MARK: - Showing / hiding

    func show(text: String, at mouse: NSPoint, target: SelectionTarget? = nil) {
        self.text = text
        self.target = target
        workTask?.cancel()
        hideTask?.cancel()
        phase = .compact
        anchorTopLeft = NSPoint(x: mouse.x + 10, y: mouse.y + 36)
        layout(animated: false)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        workTask?.cancel()
        hideTask?.cancel()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            self?.debugBackdrop?.orderOut(nil)
        })
    }

    private func hideSoon(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    /// Resize the panel to fit its content, keeping the top-left corner pinned and staying on screen.
    func layout(animated: Bool) {
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        size.width = max(size.width, 40)
        size.height = max(size.height, 30)
        var origin = NSPoint(x: anchorTopLeft.x, y: anchorTopLeft.y - size.height)
        let screen = NSScreen.screens.first { NSMouseInRect(anchorTopLeft, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            if origin.x + size.width > vf.maxX - 8 { origin.x = vf.maxX - 8 - size.width }
            if origin.x < vf.minX + 8 { origin.x = vf.minX + 8 }
            if origin.y < vf.minY + 8 { origin.y = vf.minY + 8 }
            if origin.y + size.height > vf.maxY - 8 { origin.y = vf.maxY - 8 - size.height }
        }
        let frame = NSRect(origin: origin, size: size)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    // MARK: - Actions

    func copyOriginal() {
        Clipboard.setString(text)
        finish(.done("Copied"), after: 0.6)
    }

    /// Runs an action and puts the result straight into the document — no preview step.
    /// Holding ⌥ copies the result instead of replacing.
    func perform(_ action: MousiAction, copyInstead: Bool = false) {
        guard Settings.isConfigured else {
            finish(.error("Add your API key in Mousi → Settings."), after: 3.5)
            return
        }
        let copyOnly = copyInstead || NSEvent.modifierFlags.contains(.option) || Settings.alwaysCopy
        phase = .working(action.label)
        layout(animated: true)
        let source = text
        workTask?.cancel()
        workTask = Task { @MainActor [weak self] in
            do {
                let result = try await ClaudeClient.run(action, on: source)
                guard let self, !Task.isCancelled else { return }
                switch action.presents {
                case .note:
                    self.finish(.note(action.label, result), after: 9)
                case .apply:
                    if copyOnly {
                        Clipboard.setString(result)
                        self.finish(.done("Copied"), after: 0.8)
                    } else {
                        let replaced = await self.apply(result)
                        self.finish(.done(replaced ? action.doneVerb : "Copied"), after: 0.8)
                    }
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.finish(.error(error.localizedDescription), after: 5)
            }
        }
    }

    /// Write the result back over the selection. Tries the Accessibility API first (instant,
    /// leaves the clipboard alone), falls back to a paste, and copies if the field is read-only.
    private func apply(_ result: String) async -> Bool {
        // 1. Write straight into the element the text came from. Instant, keeps the
        //    clipboard, and stays in that app's undo stack.
        if let target, Accessibility.replaceSelection(with: result, in: target) { return true }
        // 2. Some apps only accept the write while they're frontmost — put them back and retry.
        if let target, await target.reactivate(),
           Accessibility.replaceSelection(with: result, in: target) { return true }
        // 3. Otherwise paste into that same app.
        if await Clipboard.pasteIfPossible(result, into: target) { return true }
        // 4. Read-only text: the best we can do is hand it over.
        Clipboard.setString(result)
        return false
    }

    private func finish(_ p: Phase, after seconds: Double) {
        phase = p
        layout(animated: true)
        hideSoon(after: seconds)
    }

    func copyNote(_ body: String) {
        Clipboard.setString(body)
        finish(.done("Copied"), after: 0.6)
    }

    // MARK: - Debug helpers (screenshots / UI checks without a real selection)

    func debugShow(state: String) {
        let phaseFor = PillController.sampleStates().first { $0.0 == "pill-\(state)" }?.1 ?? .compact
        let screen = (NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        show(text: "hey kai do u wanna buy a new polestar 3 and also come by and test drive",
             at: NSPoint(x: screen.midX - 150, y: screen.midY))
        phase = phaseFor
        layout(animated: false)
        hideTask?.cancel()

        if ProcessInfo.processInfo.environment["MOUSI_DEBUG_BACKDROP"] != nil {
            let f = panel.frame.insetBy(dx: -60, dy: -60)
            let w = NSWindow(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
            w.isOpaque = true
            w.hasShadow = false
            w.contentView = NSHostingView(rootView:
                LinearGradient(colors: [Color(red: 0.93, green: 0.94, blue: 0.98),
                                        Color(red: 0.80, green: 0.86, blue: 0.98),
                                        Color(red: 0.90, green: 0.82, blue: 0.96)],
                               startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea())
            w.orderFrontRegardless()
            debugBackdrop = w
            panel.orderFrontRegardless()
        }
    }
    private var debugBackdrop: NSWindow?

    static func sampleStates() -> [(String, Phase)] {
        [
            ("pill-compact", .compact),
            ("pill-working", .working("Professional")),
            ("pill-done", .done("Replaced")),
            ("pill-note", .note("Before I send…", "- The message promises delivery “next week” — you may not be able to commit to that yet.\n- No sensitive data found.")),
            ("pill-error", .error("Claude Code isn't signed in. Run `claude` in Terminal and log in, then try again.")),
        ]
    }
}
