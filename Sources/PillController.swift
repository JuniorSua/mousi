import AppKit
import SwiftUI

@MainActor
final class PillController: ObservableObject {
    enum Phase: Equatable {
        case compact
        case copied
        case loading
        case results(Rewrites)
        case prompt(String)
        case error(String)

        static func == (a: Phase, b: Phase) -> Bool {
            switch (a, b) {
            case (.compact, .compact), (.copied, .copied), (.loading, .loading): return true
            case (.results(let x), .results(let y)):
                return x.corrected == y.corrected && x.professional == y.professional && x.friendly == y.friendly
            case (.prompt(let x), .prompt(let y)): return x == y
            case (.error(let x), .error(let y)): return x == y
            default: return false
            }
        }
    }

    @Published var phase: Phase = .compact
    @Published var flash: String? = nil // transient "Copied"/"Replaced" toast in the results view

    private(set) var text: String = ""
    private let panel: NSPanel
    private let hosting: NSHostingView<PillRootView>
    private var anchorTopLeft: NSPoint = .zero
    private var hideTask: Task<Void, Never>?
    private var rewriteTask: Task<Void, Never>?

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

    func show(text: String, at mouse: NSPoint) {
        self.text = text
        rewriteTask?.cancel()
        hideTask?.cancel()
        phase = .compact
        flash = nil
        // Just above and to the right of the cursor, Apple-callout style.
        anchorTopLeft = NSPoint(x: mouse.x + 10, y: mouse.y + 40)
        layout(animated: false)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        rewriteTask?.cancel()
        hideTask?.cancel()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
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

    /// Resize the panel to fit its SwiftUI content, keeping the top-left corner pinned
    /// so it grows down/right from where it first appeared, and stays on screen.
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
                ctx.duration = 0.18
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
        phase = .copied
        layout(animated: true)
        hideSoon(after: 0.7)
    }

    func rewrite() {
        runTask { source in .results(try await ClaudeClient.rewrite(source)) }
    }

    func enhancePrompt() {
        runTask { source in .prompt(try await ClaudeClient.enhancePrompt(source).prompt) }
    }

    private func runTask(_ work: @escaping (String) async throws -> Phase) {
        guard Settings.backend == .subscription || Settings.apiKey?.isEmpty == false else {
            phase = .error("Add your API key in Mousi → Settings.")
            layout(animated: true)
            hideSoon(after: 3.5)
            return
        }
        phase = .loading
        layout(animated: true)
        let source = text
        rewriteTask?.cancel()
        rewriteTask = Task { @MainActor [weak self] in
            do {
                let next = try await work(source)
                guard let self, !Task.isCancelled else { return }
                self.phase = next
                self.layout(animated: true)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.phase = .error(error.localizedDescription)
                self.layout(animated: true)
                self.hideSoon(after: 5)
            }
        }
    }

    func copy(_ s: String) {
        Clipboard.setString(s)
        toast("Copied")
        hideSoon(after: 0.6)
    }

    func replace(_ s: String) {
        toast("Replaced")
        Task { @MainActor in
            await Clipboard.paste(s)
            self.hide()
        }
    }

    private func toast(_ s: String) {
        withAnimation(.easeOut(duration: 0.15)) { flash = s }
    }

    /// Debug: put the panel at the centre of the main screen in a sample state and leave it there.
    func debugShow(state: String) {
        let sample = PillController.sampleStates()
        let phaseFor = sample.first { $0.0 == "pill-\(state)" }?.1 ?? .compact
        let screen = (NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor } ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        show(text: "me and him was going to the store yesterday but it were closed",
             at: NSPoint(x: screen.midX - 150, y: screen.midY))
        phase = phaseFor
        layout(animated: false)
        hideTask?.cancel()

        // Optional neutral backdrop for screenshots (MOUSI_DEBUG_BACKDROP=1) so no on-screen content leaks.
        if ProcessInfo.processInfo.environment["MOUSI_DEBUG_BACKDROP"] != nil {
            let f = panel.frame.insetBy(dx: -60, dy: -60)
            let w = NSWindow(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
            w.isOpaque = true
            w.hasShadow = false
            w.contentView = NSHostingView(rootView:
                LinearGradient(colors: [Color(red: 0.93, green: 0.94, blue: 0.98), Color(red: 0.80, green: 0.86, blue: 0.98), Color(red: 0.90, green: 0.82, blue: 0.96)],
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
            ("pill-loading", .loading),
            ("pill-results", .results(Rewrites(
                corrected: "He and I were going to the store yesterday, but it was closed.",
                professional: "He and I went to the store yesterday, but unfortunately it was closed.",
                friendly: "He and I headed to the store yesterday, but it turned out to be closed."))),
            ("pill-prompt", .prompt("Write a warm, concise follow-up email to Kai about the Polestar 3 he test-drove last week.\n\nContext: he liked the range but hesitated on price. Goal: invite him back for a second drive and mention current financing.\n\nRequirements: under 120 words, friendly but professional, one clear call to action, no pressure tactics. Output the email only.")),
            ("pill-error", .error("Add your API key in Mousi → Settings.")),
        ]
    }

    // MARK: - Debug rendering (used by the build check to eyeball the UI without a real selection)

    static func debugRender(to directory: URL) async {
        let c = PillController()
        c.text = "me and him was going to the store yesterday but it were closed"
        let states = sampleStates()
        for (name, phase) in states {
            c.phase = phase
            let view = PillRootView(controller: c).frame(width: nil).padding(24)
                .background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent("\(name).png"))
            }
        }
    }
}
