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
        // Wait for TextEdit to genuinely own the front, retrying activation. Everything after this
        // point types and replaces text through synthetic events, so if it ran against the wrong
        // app it would edit the user's real documents. Refuse to continue rather than risk that.
        var frontmost = false
        for attempt in 0..<15 {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit" { frontmost = true; break }
            if attempt % 5 == 4 {
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first?
                    .activate(options: [.activateAllWindows])
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        check("TextEdit frontmost", frontmost, NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")
        guard frontmost else {
            print("\nABORTED: TextEdit never came to the front, so the remaining checks would have")
            print("typed into whatever app was in front instead. Nothing was modified.")
            print("\n\(pass) passed, \(fail) failed (aborted early)")
            NSApp.terminate(nil); return
        }

        // 1) Selection reading — select all, then read it back through the same code path the pill uses.
        var read: String?
        for _ in 0..<8 {
            KeySender.send(keyCode: 0, command: true)  // ⌘A
            try? await Task.sleep(nanoseconds: 300_000_000)
            read = Accessibility.selectedText()?.trimmingCharacters(in: .whitespacesAndNewlines)
            if read?.isEmpty == false { break }
        }
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

        // 5) The whole real path: drag-select, the running Mousi shows its pill, click
        //    Professional, and the document text must actually change. This is the flow that
        //    matters — checking replaceSelection() in isolation passes even when it's broken,
        //    because in isolation nothing has stolen focus from the text field.
        if let el = firstFocusedElement(), let rect = frame(of: el) {
            drag(from: CGPoint(x: rect.minX + 12, y: rect.minY + 10),
                 to: CGPoint(x: rect.minX + 300, y: rect.minY + 10))
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            check("Drag-select shows the pill", pillIsOnScreen())

            let before = documentText()
            let clipAtClick = NSPasteboard.general.changeCount
            if let button = findButton(titled: "Professional", inPidOtherThan: ProcessInfo.processInfo.processIdentifier),
               let bRect = frame(of: button) {
                click(at: CGPoint(x: bRect.midX, y: bRect.midY))
                var changed = false
                for _ in 0..<40 {                       // up to 20s for the model round trip
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if let now = documentText(), let before, now != before { changed = true; break }
                }
                let after = documentText() ?? ""
                check("Clicking Professional REPLACES the text in the document", changed,
                      changed ? "\"\(after.prefix(60))…\"" : "document unchanged — result was not written back")
                // The whole point of the fix: it must go in through the Accessibility API,
                // not degrade to putting the text on the clipboard.
                check("Replaced without touching the clipboard",
                      changed && NSPasteboard.general.changeCount == clipAtClick,
                      NSPasteboard.general.changeCount == clipAtClick ? "" : "clipboard was used — it fell back to copy")
            } else {
                check("Clicking Professional REPLACES the text", false, "could not find the Professional button")
            }
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

        // 7) A ⋯ menu action must replace too — menu items are a different path to perform().
        try? await Task.sleep(nanoseconds: 400_000_000)
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first?
            .activate(options: [.activateAllWindows])
        try? await Task.sleep(nanoseconds: 900_000_000)
        if let el = firstFocusedElement(), let rect = frame(of: el) {
            drag(from: CGPoint(x: rect.minX + 12, y: rect.minY + 10),
                 to: CGPoint(x: rect.minX + 300, y: rect.minY + 10))
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            let mePid = ProcessInfo.processInfo.processIdentifier
            let otherPid = NSWorkspace.shared.runningApplications
                .first { $0.localizedName == "Mousi" && $0.processIdentifier != mePid }?.processIdentifier
            // SwiftUI's Menu isn't an AXButton, so aim at the trailing edge of the pill instead.
            if let otherPid, let pRect = pillFrame(ownedBy: otherPid) {
                let before = documentText()
                click(at: CGPoint(x: pRect.maxX - 26, y: pRect.midY))
                try? await Task.sleep(nanoseconds: 900_000_000)
                if let item = findMenuItem(titled: "Shorten", inPidOtherThan: mePid) {
                    AXUIElementPerformAction(item, kAXPressAction as CFString)
                    var changed = false
                    for _ in 0..<40 {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if let now = documentText(), let before, now != before { changed = true; break }
                    }
                    check("⋯ menu action (Shorten) replaces the text", changed,
                          changed ? "\"\((documentText() ?? "").prefix(60))…\"" : "document unchanged")
                } else {
                    check("⋯ menu action (Shorten) replaces the text", false, "menu item not found")
                    KeySender.sendPlain(keyCode: 53)
                }
            } else {
                check("⋯ menu action (Shorten) replaces the text", false, "pill window not found")
            }
        } else {
            check("⋯ menu action (Shorten) replaces the text", false, "TextEdit text area not focused")
        }

        print("\n\(pass) passed, \(fail) failed")
        NSApp.terminate(nil)
    }

    /// TextEdit applies smart quotes and dashes, so compare on the plain forms.
    private static func normalise(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{2019}", with: "'")
         .replacingOccurrences(of: "\u{201C}", with: "\"")
         .replacingOccurrences(of: "\u{201D}", with: "\"")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: helpers

    /// Whole contents of the frontmost text area.
    private static func documentText() -> String? {
        guard let el = firstFocusedElement() else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    /// Finds a button by title anywhere in another process's accessibility tree.
    private static func findButton(titled title: String, inPidOtherThan me: pid_t) -> AXUIElement? {
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.localizedName == "Mousi" && $0.processIdentifier != me
        }
        for app in others {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            if let hit = search(root, title: title, depth: 0) { return hit }
        }
        return nil
    }

    private static func findMenuItem(titled title: String, inPidOtherThan me: pid_t) -> AXUIElement? {
        for app in NSWorkspace.shared.runningApplications where app.localizedName == "Mousi" && app.processIdentifier != me {
            if let hit = search(AXUIElementCreateApplication(app.processIdentifier), title: title,
                                depth: 0, role: "AXMenuItem") { return hit }
        }
        return nil
    }

    private static func search(_ el: AXUIElement, title: String, depth: Int) -> AXUIElement? {
        search(el, title: title, depth: depth, role: "AXButton")
    }

    private static func search(_ el: AXUIElement, title: String, depth: Int, role wanted: String) -> AXUIElement? {
        if depth > 12 { return nil }
        var roleRef: CFTypeRef?, titleRef: CFTypeRef?, descRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
        AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &titleRef)
        AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descRef)
        let label = (titleRef as? String) ?? (descRef as? String) ?? ""
        if (roleRef as? String) == wanted, label.localizedCaseInsensitiveContains(title) { return el }
        var kidsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsRef) == .success,
              let kids = kidsRef as? [AXUIElement] else { return nil }
        for kid in kids { if let hit = search(kid, title: title, depth: depth + 1, role: wanted) { return hit } }
        return nil
    }

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
