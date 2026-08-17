import Foundation

enum Backend: String, CaseIterable, Identifiable {
    case openRouter, subscription, apiKey
    var id: String { rawValue }
    var label: String {
        switch self {
        case .openRouter: return "OpenRouter (many models, one key)"
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

    static var openRouterKey: String? {
        get { d.string(forKey: "openRouterKey") }
        set { d.set(newValue, forKey: "openRouterKey") }
    }

    /// An OpenRouter model id — one of the curated shortlist, or anything the user typed.
    static var openRouterModel: String {
        get { d.string(forKey: "openRouterModel") ?? OpenRouterClient.defaultModelID }
        set { d.set(newValue, forKey: "openRouterModel") }
    }

    /// When OpenRouter runs out of credit, rate-limits or goes down, retry the request on the
    /// Claude Code CLI instead of surfacing an error.
    static var fallbackToClaude: Bool {
        get { d.object(forKey: "fallbackToClaude") as? Bool ?? true }
        set { d.set(newValue, forKey: "fallbackToClaude") }
    }

    /// Whether the chosen backend has what it needs to run.
    static var isConfigured: Bool {
        switch backend {
        case .subscription: return true
        case .apiKey: return !(apiKey ?? "").isEmpty
        case .openRouter: return !(openRouterKey ?? "").isEmpty || (fallbackToClaude && ClaudeCLI.locate() != nil)
        }
    }

    /// Master on/off switch for the selection pill.
    static var enabled: Bool {
        get { d.object(forKey: "enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "enabled") }
    }

    /// Put results on the clipboard instead of writing them back over the selection.
    static var alwaysCopy: Bool {
        get { d.object(forKey: "alwaysCopy") as? Bool ?? false }
        set { d.set(newValue, forKey: "alwaysCopy") }
    }

    /// When Accessibility can't read the selection (some web/Electron apps),
    /// briefly borrow the clipboard (Cmd+C, read, restore) to get the text.
    static var clipboardFallback: Bool {
        get { d.object(forKey: "clipboardFallback") as? Bool ?? true }
        set { d.set(newValue, forKey: "clipboardFallback") }
    }
}
