import AppKit
import ApplicationServices

/// Marker stamped on keyboard events Mousi synthesizes (Cmd+C / Cmd+V) so the
/// global monitors don't mistake them for the user typing.
private let syntheticMarker: Int64 = 0x4D4F5553 // "MOUS"

enum KeySender {
    static func send(keyCode: CGKeyCode, command: Bool) {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else { return }
        if command {
            down.flags = .maskCommand
            up.flags = .maskCommand
        }
        down.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        up.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Same as `send` but without the ⌘ modifier, for plain keys like esc.
    static func sendPlain(keyCode: CGKeyCode) { send(keyCode: keyCode, command: false) }

    static let keyC: CGKeyCode = 8
    static let keyV: CGKeyCode = 9

    static func isSynthetic(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == syntheticMarker
    }
}

enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestIfNeeded() {
        guard !isTrusted else { return }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// The focused UI elements worth asking about the selection, best candidate first.
    private static func focusedElements() -> [AXUIElement] {
        var candidates: [AXUIElement] = []
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
           let f = focusedRef {
            candidates.append(f as! AXUIElement)
        }
        if let app = NSWorkspace.shared.frontmostApplication {
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &ref) == .success, let f = ref {
                candidates.append(f as! AXUIElement)
            }
        }
        return candidates
    }

    /// Writes `text` over the current selection directly through the Accessibility API.
    /// Instant when it works, leaves the clipboard untouched, and stays in the app's undo stack.
    static func replaceSelection(with text: String) -> Bool {
        for el in focusedElements() {
            var settable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settable) == .success,
                  settable.boolValue else { continue }
            if AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success {
                return true
            }
        }
        return false
    }

    /// Whether the focused element looks like somewhere a paste would land.
    static func focusedIsEditable() -> Bool {
        let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        for el in focusedElements() {
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String, editableRoles.contains(role) { return true }
            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success,
               settable.boolValue { return true }
        }
        return false
    }

    /// Reads the currently selected text from the focused UI element via the Accessibility API.
    static func selectedText() -> String? {
        for el in focusedElements() {
            var textRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &textRef) == .success,
               let s = textRef as? String,
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s
            }
        }
        return nil
    }
}

enum Clipboard {
    static func setString(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    private static func snapshot() -> [[(NSPasteboard.PasteboardType, Data)]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
    }

    private static func restore(_ snap: [[(NSPasteboard.PasteboardType, Data)]]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let items = snap.map { entries -> NSPasteboardItem in
            let it = NSPasteboardItem()
            for (t, d) in entries { it.setData(d, forType: t) }
            return it
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }

    /// Borrow the clipboard: send Cmd+C to the frontmost app, read what landed,
    /// then put the user's previous clipboard back.
    static func sniffSelection() async -> String? {
        let pb = NSPasteboard.general
        let saved = snapshot()
        let before = pb.changeCount
        KeySender.send(keyCode: KeySender.keyC, command: true)
        var changed = false
        for _ in 0..<12 { // up to ~300ms
            try? await Task.sleep(nanoseconds: 25_000_000)
            if pb.changeCount != before { changed = true; break }
        }
        let text = changed ? pb.string(forType: .string) : nil
        if changed { restore(saved) }
        guard let t = text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return t
    }

    /// Paste only where a paste can actually land; reports whether it was attempted.
    static func pasteIfPossible(_ s: String) async -> Bool {
        guard Accessibility.focusedIsEditable() else { return false }
        await paste(s)
        return true
    }

    /// Put `s` on the clipboard and paste it into the frontmost app, then restore the clipboard.
    static func paste(_ s: String) async {
        let saved = snapshot()
        setString(s)
        try? await Task.sleep(nanoseconds: 40_000_000)
        KeySender.send(keyCode: KeySender.keyV, command: true)
        try? await Task.sleep(nanoseconds: 250_000_000)
        restore(saved)
    }
}

/// Watches the mouse globally; when the user drags or double/triple-clicks to
/// select text, captures the selection and reports it with the mouse position.
@MainActor
final class SelectionMonitor {
    var onSelection: ((String, NSPoint) -> Void)?
    var onDismiss: (() -> Void)?

    private var monitors: [Any] = []
    private var downPoint: NSPoint?
    private var captureTask: Task<Void, Never>?
    private var generation = 0

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            Task { @MainActor in self?.handle(e) }
        }) { monitors.append(m) }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        captureTask?.cancel()
    }

    @objc private func appActivated(_ n: Notification) {
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
        Task { @MainActor in self.onDismiss?() }
    }

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDown:
            downPoint = NSEvent.mouseLocation
            cancelCapture()
            onDismiss?()
        case .rightMouseDown, .otherMouseDown, .scrollWheel:
            cancelCapture()
            onDismiss?()
        case .keyDown:
            if KeySender.isSynthetic(e) { return }
            cancelCapture()
            onDismiss?()
        case .leftMouseUp:
            let up = NSEvent.mouseLocation
            let dragged: Bool = {
                guard let d = downPoint else { return false }
                return hypot(up.x - d.x, up.y - d.y) > 5
            }()
            let multi = e.clickCount >= 2
            downPoint = nil
            guard dragged || multi else { return }
            scheduleCapture(at: up, allowClipboard: dragged || multi)
        default:
            break
        }
    }

    private func cancelCapture() {
        captureTask?.cancel()
        captureTask = nil
        generation += 1
    }

    private func scheduleCapture(at point: NSPoint, allowClipboard: Bool) {
        cancelCapture()
        let gen = generation
        captureTask = Task { @MainActor [weak self] in
            // Let the host app finish updating its selection.
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            var text = Accessibility.selectedText()
            if text == nil, allowClipboard, Settings.clipboardFallback {
                text = await Clipboard.sniffSelection()
            }
            guard !Task.isCancelled, gen == self.generation, let t = text else { return }
            self.onSelection?(t, point)
        }
    }
}
