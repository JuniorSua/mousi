import Foundation

/// Runs rewrites through OpenRouter, which fronts hundreds of models behind one key and one
/// OpenAI-shaped endpoint. Used as the primary backend so a rewrite costs a fraction of a cent
/// and isn't billed against the Claude subscription; `ClaudeCLI` picks up when this fails.
/// Same contract as the other backends — system prompt in, plain text out.
enum OpenRouterClient {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    static let keyInfoEndpoint = URL(string: "https://openrouter.ai/api/v1/key")!

    /// A small curated set — good rewrite quality per millisecond, cheapest first. Slugs checked
    /// against openrouter.ai/api/v1/models; any other id can be typed into Settings instead.
    static let models: [ModelOption] = [
        ModelOption(id: "qwen/qwen3.7-flash", name: "Qwen3.7 Flash",
                    note: "Cheapest — pennies per year at normal use"),
        ModelOption(id: "openai/gpt-5.6-luna", name: "GPT-5.6 Luna",
                    note: "Very cheap, strong at everyday prose"),
        ModelOption(id: "google/gemini-3.1-flash-lite", name: "Gemini 3.1 Flash Lite",
                    note: "Fast and reliable for grammar — recommended"),
        ModelOption(id: "google/gemini-3.7-flash", name: "Gemini 3.7 Flash",
                    note: "More polish, still quick"),
        ModelOption(id: "anthropic/claude-haiku-4.5", name: "Claude Haiku 4.5",
                    note: "Same model as the Claude backend, billed per token"),
        ModelOption(id: "x-ai/grok-4.6", name: "Grok 4.6",
                    note: "Looser, more conversational voice"),
        ModelOption(id: "anthropic/claude-sonnet-5", name: "Claude Sonnet 5",
                    note: "Most polish, slowest and priciest"),
    ]
    static let defaultModelID = "google/gemini-3.1-flash-lite"

    static func model(_ id: String) -> ModelOption? { models.first { $0.id == id } }

    // MARK: - Requests

    static func run(system: String, text: String) async throws -> String {
        guard let key = Settings.openRouterKey, !key.isEmpty else { throw ClaudeError.noRouterKey }

        let body: [String: Any] = [
            "model": Settings.openRouterModel,
            "max_tokens": 2048,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": text],
            ],
            // Rewrites don't benefit from deliberation, and reasoning tokens are pure latency.
            // OpenRouter normalises this and ignores it for models that can't reason.
            "reasoning": ["effort": "low", "exclude": true],
        ]

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        // OpenRouter uses these for its app-attribution leaderboard; harmless and polite to send.
        req.setValue("https://github.com/JuniorSua/mousi", forHTTPHeaderField: "http-referer")
        req.setValue("Mousi", forHTTPHeaderField: "x-title")
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
        if http.statusCode != 200 { throw failure(json, status: http.statusCode, data: data) }

        // OpenRouter reports upstream provider failures as a 200 with an `error` object.
        if let err = json["error"] as? [String: Any] {
            throw failure(json, status: (err["code"] as? Int) ?? 0, data: data)
        }
        guard let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else { throw ClaudeError.badResponse }
        if message["refusal"] is String { throw ClaudeError.refusal }
        guard let out = message["content"] as? String else { throw ClaudeError.badResponse }
        return out
    }

    private static func failure(_ json: [String: Any], status: Int, data: Data) -> ClaudeError {
        let msg = ((json["error"] as? [String: Any])?["message"] as? String)
            ?? (String(data: data, encoding: .utf8) ?? "unknown")
        return .http(status, msg)
    }

    /// True for failures that mean "OpenRouter can't serve this right now" — those are worth
    /// retrying on the Claude subscription. Deliberately excludes the misconfiguration codes
    /// (401/403 bad key, 404 unknown model) and refusals: falling back on those would quietly
    /// bill every rewrite to the Claude plan forever while the setup *looks* like it works.
    static func shouldFallBack(on error: ClaudeError) -> Bool {
        switch error {
        case .noRouterKey, .network:
            return true
        case .http(let code, _):
            // 402 out of credit, 408/429 limits, 5xx upstream outages, 0 unattributed.
            return code == 0 || code == 402 || code == 408 || code == 429 || code >= 500
        case .refusal, .badResponse, .noKey, .cliMissing, .cliNotLoggedIn:
            return false
        }
    }

    /// Settings "Test" button: validates the key and reports what's left on it.
    static func testKey(_ key: String) async -> Result<String, ClaudeError> {
        var req = URLRequest(url: keyInfoEndpoint)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        req.timeoutInterval = 20
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            guard code == 200 else {
                let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? "check failed"
                return .failure(.http(code, msg))
            }
            let info = json["data"] as? [String: Any] ?? [:]
            let used = info["usage"] as? Double ?? 0
            if let limit = info["limit"] as? Double {
                return .success(String(format: "Works — $%.2f left", max(0, limit - used)))
            }
            return .success("Works")
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}
