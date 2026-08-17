import Foundation

enum ClaudeError: LocalizedError {
    case noKey
    case http(Int, String)
    case refusal
    case badResponse
    case network(String)
    case cliMissing
    case cliNotLoggedIn
    case noRouterKey

    var errorDescription: String? {
        switch self {
        case .noKey: return "Add your Anthropic API key in Mousi → Settings."
        case .noRouterKey: return "Add your OpenRouter key in Mousi → Settings."
        case .cliMissing: return "Claude Code isn't installed. Install it, or switch to an API key in Settings."
        case .cliNotLoggedIn: return "Claude Code isn't signed in. Run `claude` in Terminal and log in, then try again."
        case .http(let code, let msg): return code == 0 ? msg : "API error \(code): \(msg)"
        case .refusal: return "Claude declined to work on this text."
        case .badResponse: return "Unexpected response from Claude."
        case .network(let m): return "Network error: \(m)"
        }
    }
}

struct ModelOption: Identifiable, Hashable {
    let id: String
    let name: String
    let note: String

    static let all: [ModelOption] = [
        ModelOption(id: "claude-haiku-4-5", name: "Claude Haiku 4.5", note: "Fastest & lightest — recommended"),
        ModelOption(id: "claude-sonnet-5", name: "Claude Sonnet 5", note: "More polish, a little slower"),
        ModelOption(id: "claude-opus-5", name: "Claude Opus 5", note: "Most capable, slowest"),
    ]
    static let defaultID = "claude-haiku-4-5"
}

enum ClaudeClient {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Runs one action over the selected text and returns the resulting text.
    /// Single plain-text output — roughly twice as fast as asking for structured JSON.
    static func run(_ action: MousiAction, on text: String) async throws -> String {
        let system = systemPrompt(for: action, input: text)
        let raw = try await dispatch(system: system, text: text)
        let cleaned = sanitize(raw, original: text)
        guard !cleaned.isEmpty else { throw ClaudeError.badResponse }
        return cleaned
    }

    /// Sends the request to the configured backend. On OpenRouter, a failure that just means
    /// "not available right now" (out of credit, rate-limited, offline, no key) falls through to
    /// the Claude subscription rather than failing the rewrite in front of the user.
    private static func dispatch(system: String, text: String) async throws -> String {
        switch Settings.backend {
        case .subscription:
            return try await ClaudeCLI.run(system: system, text: text, model: Settings.model)
        case .apiKey:
            return try await runViaAPI(system: system, text: text)
        case .openRouter:
            do {
                return try await OpenRouterClient.run(system: system, text: text)
            } catch let e as ClaudeError where Settings.fallbackToClaude
                && OpenRouterClient.shouldFallBack(on: e) && ClaudeCLI.locate() != nil {
                return try await ClaudeCLI.run(system: system, text: text, model: Settings.model)
            }
        }
    }

    /// Adds a concrete word cap for length-sensitive actions. Stating an actual number works;
    /// asking a small model to "keep it about twice the length" does not.
    static func systemPrompt(for action: MousiAction, input: String) -> String {
        guard let mult = action.lengthMult else { return action.system }
        let words = max(1, input.split { $0.isWhitespace || $0.isNewline }.count)
        let cap = max(action.lengthFloor, Int((Double(words) * mult).rounded()))
        return action.system + """
        \n
        Hard length limit for this request: the user's text is \(words) words, so your output must be \
        at most \(cap) words. Staying under this matters more than covering everything.
        """
    }

    /// Models occasionally wrap output in quotes or a code fence, or open with a stock lead-in.
    /// Strip those so what lands in the document is exactly the text.
    static func sanitize(_ s: String, original: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)

        if t.hasPrefix("```") {
            var lines = t.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeLast() }
            t = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // A stock lead-in line ("Here's the rewrite:") followed by a blank line and the real content.
        if let firstBreak = t.range(of: "\n\n") {
            let head = String(t[t.startIndex..<firstBreak.lowerBound])
            let leadIn = ["here's", "here is", "sure,", "certainly", "of course"]
            if head.count < 90, head.hasSuffix(":"),
               leadIn.contains(where: { head.lowercased().hasPrefix($0) }) {
                t = String(t[firstBreak.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Wrapping quotes the original didn't have.
        let pairs: [(Character, Character)] = [("\"", "\""), ("\u{201C}", "\u{201D}"), ("'", "'")]
        let originalTrimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in pairs where t.count > 2 && t.first == open && t.last == close {
            if originalTrimmed.first == open { break }
            let inner = String(t.dropFirst().dropLast())
            if !inner.contains(close) { t = inner }
            break
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - API-key backend

    static func runViaAPI(system: String, text: String) async throws -> String {
        guard let key = Settings.apiKey, !key.isEmpty else { throw ClaudeError.noKey }
        let body: [String: Any] = [
            "model": Settings.model,
            "max_tokens": 2048,
            "system": system,
            "messages": [["role": "user", "content": text]],
        ]
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw ClaudeError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeError.badResponse
        }
        if http.statusCode != 200 {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String)
                ?? (String(data: data, encoding: .utf8) ?? "unknown")
            throw ClaudeError.http(http.statusCode, msg)
        }
        if json["stop_reason"] as? String == "refusal" { throw ClaudeError.refusal }
        guard let content = json["content"] as? [[String: Any]],
              let block = content.first(where: { $0["type"] as? String == "text" }),
              let out = block["text"] as? String else { throw ClaudeError.badResponse }
        return out
    }

    /// Cheap connectivity/key check used by the Settings "Test" button.
    static func testKey(_ key: String) async -> Result<Void, ClaudeError> {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 20
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return .success(()) }
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? "check failed"
            return .failure(.http(code, msg))
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}
