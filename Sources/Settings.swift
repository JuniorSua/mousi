import Foundation

enum Backend: String, CaseIterable, Identifiable {
    case subscription, apiKey
    var id: String { rawValue }
    var label: String {
        switch self {
        case .subscription: return "My Claude subscription (via Claude Code)"
        case .apiKey: return "Anthropic API key"
        }
    }
}

enum Settings {
    private static let d = UserDefaults.standard

    static var backend: Backend {
        get { Backend(rawValue: d.string(forKey: "backend") ?? "") ?? .subscription }
        set { d.set(newValue.rawValue, forKey: "backend") }
    }

    /// Optional override for the `claude` binary location.
    static var claudePath: String? {
        get { d.string(forKey: "claudePath") }
        set { d.set(newValue, forKey: "claudePath") }
    }

    static var apiKey: String? {
        get { d.string(forKey: "apiKey") }
        set { d.set(newValue, forKey: "apiKey") }
    }

    static var model: String {
        get { d.string(forKey: "model") ?? ModelOption.defaultID }
        set { d.set(newValue, forKey: "model") }
    }

    /// Master on/off switch for the selection pill.
    static var enabled: Bool {
        get { d.object(forKey: "enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "enabled") }
    }

    /// When Accessibility can't read the selection (some web/Electron apps),
    /// briefly borrow the clipboard (Cmd+C, read, restore) to get the text.
    static var clipboardFallback: Bool {
        get { d.object(forKey: "clipboardFallback") as? Bool ?? true }
        set { d.set(newValue, forKey: "clipboardFallback") }
    }
}
