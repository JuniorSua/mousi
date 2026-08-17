import AppKit
import ApplicationServices

/// End-to-end check of the parts that can only be verified against a real app:
/// Accessibility trust, reading a selection, writing it back in place, and whether a
/// genuine mouse drag makes the running Mousi show its pill.
/// Run with:  MOUSI_DEBUG_SELFTEST=1 ./build/Mousi.app/Contents/MacOS/Mousi
@MainActor
enum SelfTest {
    private static let original = "me and him was going to the store yesterday but it were closed"
    private static let replacement = "He and I went to the store yesterday, but it was closed."
    private static let path = "/tmp/mousi-selftest.txt"

    static func run() async {
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
            ok ? (pass += 1) : (fail += 1)
        }

        check("Accessibility trusted", Accessibility.isTrusted)
        guard Accessibility.isTrusted else {
            print("\nCannot continue: grant Accessibility to this binary, then re-run.")
            NSApp.terminate(nil); return
        }

        // Open a scratch document in TextEdit.
        try? original.write(toFile: path, atomically: true, encoding: .utf8)
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        if let te = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            _ = try? await NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: te, configuration: cfg)
        }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        check("TextEdit frontmost", NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit",
              NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")

        // 1) Selection reading — select all, then read it back through the same code path the pill uses.
        KeySender.send(keyCode: 0, command: true)  // ⌘A
        try? await Task.sleep(nanoseconds: 600_000_000)
        let read = Accessibility.selectedText()?.trimmingCharacters(in: .whitespacesAndNewlines)
        check("Reads selection via AX", read == original, read.map { "got \"\($0.prefix(40))…\"" } ?? "got nil")

        // 2) Editability probe used to decide replace-vs-copy.
        check("Detects an editable target", Accessibility.focusedIsEditable())

        // 3) The core one: write the result straight back over the selection.
        let clipBefore = NSPasteboard.general.changeCount
        let replaced = Accessibility.replaceSelection(with: replacement)
        try? await Task.sleep(nanoseconds: 500_000_000)
        check("Replaces selection in place", replaced)
        let after = (try? String(contentsOfFile: path, encoding: .utf8)) // file is stale until saved
        _ = after
        KeySender.send(keyCode: 0, command: true)  // ⌘A again to read the new contents
        try? await Task.sleep(nanoseconds: 500_000_000)
        let now = Accessibility.selectedText()?.trimmingCharacters(in: .whitespacesAndNewlines)
        check("Document now holds the new text", now == replacement, now.map { "\"\($0.prefix(50))…\"" } ?? "nil")
        check("Clipboard untouched by replace", NSPasteboard.general.changeCount == clipBefore)

        // 4) Undo must put the user's words back.
        KeySender.send(keyCode: 6, command: true)  // ⌘Z
        try? await Task.sleep(nanoseconds: 700_000_000)
        KeySender.send(keyCode: 0, command: true)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let undone = Accessibility.selectedText()?.trimmingCharacters(in: .whitespacesAndNewlines)
        check("⌘Z restores the original", undone == original, undone.map { "\"\($0.prefix(50))…\"" } ?? "nil")

        // 5) A real drag selection should make the already-running Mousi show its pill.
        if let el = firstFocusedElement(), let rect = frame(of: el) {
            let from = CGPoint(x: rect.minX + 12, y: rect.minY + 10)
            let to = CGPoint(x: rect.minX + 260, y: rect.minY + 10)
            drag(from: from, to: to)
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            check("Drag-select shows the pill", pillIsOnScreen())
        } else {
            check("Drag-select shows the pill", false, "could not locate the text area")
        }

        // 6) The ⋯ menu is how most actions are reached — make sure it opens from a
        //    non-activating panel, which is not a given.
        let pill = PillController()
        pill.show(text: original, at: NSPoint(x: 600, y: 500))
        pill.layout(animated: false)
        try? await Task.sleep(nanoseconds: 700_000_000)
        if let frame = pillFrame(ownedBy: ProcessInfo.processInfo.processIdentifier) {
            // ⋯ sits at the trailing edge, inside the 12pt shadow padding.
            let target = CGPoint(x: frame.maxX - 26, y: frame.midY)
            click(at: target)
            try? await Task.sleep(nanoseconds: 900_000_000)
            check("⋯ menu opens", menuIsOpen())
            KeySender.sendPlain(keyCode: 53) // esc
            try? await Task.sleep(nanoseconds: 300_000_000)
        } else {
            check("⋯ menu opens", false, "pill window not found")
        }
        pill.hide()

        print("\n\(pass) passed, \(fail) failed")
        NSApp.terminate(nil)
    }

    // MARK: helpers

    private static func firstFocusedElement() -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                            kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let f = ref else { return nil }
        return (f as! AXUIElement)
    }

    private static func frame(of el: AXUIElement) -> CGRect? {
        var pRef: CFTypeRef?, sRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sRef) == .success
        else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(pRef as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sRef as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    private static func drag(from: CGPoint, to: CGPoint) {
        let src = CGEventSource(stateID: .combinedSessionState)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: from, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)?.post(tap: .cghidEventTap)
        for i in 1...10 {
            let t = CGFloat(i) / 10
            let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(25_000)
        }
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private static func pillFrame(ownedBy pid: Int32) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list where (w[kCGWindowOwnerPID as String] as? Int).map({ $0 == Int(pid) }) ?? false {
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = b["Width"], width > 100, width < 500 else { continue }
            return CGRect(x: b["X"]!, y: b["Y"]!, width: width, height: b["Height"]!)
        }
        return nil
    }

    private static func click(at p: CGPoint) {
        let src = CGEventSource(stateID: .combinedSessionState)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(120_000)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(60_000)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// An open NSMenu shows up as a separate high-layer window.
    private static func menuIsOpen() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { w in
            (w[kCGWindowOwnerPID as String] as? Int).map { $0 == Int(ProcessInfo.processInfo.processIdentifier) } ?? false
                && ((w[kCGWindowLayer as String] as? Int) ?? 0) >= 100
        }
    }

    /// Looks for the running Mousi's floating pill (its own panel sits at window layer 24/25).
    private static func pillIsOnScreen() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { w in
            (w[kCGWindowOwnerName as String] as? String) == "Mousi"
                && (w[kCGWindowOwnerPID as String] as? Int).map { $0 != Int(me) } ?? false
                && ((w[kCGWindowLayer as String] as? Int) ?? 0) >= 20
        }
    }
}
