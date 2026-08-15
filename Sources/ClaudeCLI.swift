import Foundation

/// Runs rewrites through the locally installed Claude Code CLI (`claude -p`), which is
/// signed in with the user's Claude subscription — no API key needed.
enum ClaudeCLI {
    /// Where the `claude` binary usually lives. First existing path wins; a login-shell
    /// `which claude` is the fallback.
    static func locate() -> String? {
        if let custom = Settings.claudePath, !custom.isEmpty, FileManager.default.isExecutableFile(atPath: custom) {
            return custom
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.npm-global/bin/claude",
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
        ]
        if let p = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return p }
        // Ask the user's login shell (picks up nvm/volta/etc.).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            p.waitUntilExit()
            let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !s.isEmpty, FileManager.default.isExecutableFile(atPath: s) { return s }
        }
        return nil
    }

    /// Model alias understood by the CLI for a Mousi model id.
    static func alias(for modelID: String) -> String {
        if modelID.contains("haiku") { return "haiku" }
        if modelID.contains("sonnet") { return "sonnet" }
        if modelID.contains("opus") { return "opus" }
        return "haiku"
    }

    struct Output {
        let isError: Bool
        let result: String
        let structured: [String: Any]?
    }

    static func run(prompt: String, systemPrompt: String?, jsonSchema: [String: Any]?, model: String) async throws -> Output {
        guard let bin = locate() else { throw ClaudeError.cliMissing }
        var args = ["-p", "--output-format", "json", "--no-session-persistence",
                    "--tools", "", "--setting-sources", "", "--model", model, "--effort", "low"]
        if let s = systemPrompt { args += ["--system-prompt", s] }
        if let schema = jsonSchema,
           let data = try? JSONSerialization.data(withJSONObject: schema),
           let str = String(data: data, encoding: .utf8) {
            args += ["--json-schema", str]
        }
        args.append(prompt)

        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bin)
                p.arguments = args
                var env = ProcessInfo.processInfo.environment
                let binDir = (bin as NSString).deletingLastPathComponent
                // /usr/sbin and /sbin are required — without them the CLI can't reach the keychain login.
                env["PATH"] = "\(binDir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
                env["USER"] = NSUserName()
                // Rewrites don't need extended thinking; without this Haiku spends 10–30s deliberating.
                env["MAX_THINKING_TOKENS"] = "0"
                env.removeValue(forKey: "CLAUDECODE")
                env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
                p.environment = env
                p.currentDirectoryURL = FileManager.default.temporaryDirectory
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(throwing: ClaudeError.network("Could not start Claude CLI: \(error.localizedDescription)"))
                    return
                }
                // Drain both pipes concurrently so neither can block the process on a full buffer.
                var errData = Data()
                let errGroup = DispatchGroup()
                errGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    errGroup.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                errGroup.wait()
                p.waitUntilExit()
                guard let json = try? JSONSerialization.jsonObject(with: outData) as? [String: Any] else {
                    let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    cont.resume(throwing: ClaudeError.http(Int(p.terminationStatus), msg.isEmpty ? "Claude CLI returned no output" : msg))
                    return
                }
                let isError = json["is_error"] as? Bool ?? (p.terminationStatus != 0)
                let result = json["result"] as? String ?? ""
                cont.resume(returning: Output(isError: isError, result: result, structured: json["structured_output"] as? [String: Any]))
            }
        }
    }

    /// Runs a structured task and returns the raw JSON payload matching its schema.
    static func structured(_ task: ClaudeTask, text: String, model: String) async throws -> Data {
        let out = try await run(prompt: text, systemPrompt: task.system, jsonSchema: task.schema, model: alias(for: model))
        if out.isError {
            if out.result.lowercased().contains("not logged in") { throw ClaudeError.cliNotLoggedIn }
            throw ClaudeError.http(0, out.result.isEmpty ? "Claude CLI error" : out.result)
        }
        if let s = out.structured, let d = try? JSONSerialization.data(withJSONObject: s) { return d }
        guard let d = out.result.data(using: .utf8), !d.isEmpty else { throw ClaudeError.badResponse }
        if (try? JSONSerialization.jsonObject(with: d)) != nil { return d }
        // The model answered in plain text; if the schema has a single string field, wrap it.
        if let props = task.schema["properties"] as? [String: Any], props.count == 1, let key = props.keys.first,
           let wrapped = try? JSONSerialization.data(withJSONObject: [key: out.result]) {
            return wrapped
        }
        throw ClaudeError.badResponse
    }

    static func test() async -> Result<Void, ClaudeError> {
        do {
            let out = try await run(prompt: "Reply with exactly: OK", systemPrompt: nil, jsonSchema: nil, model: "haiku")
            if out.isError {
                if out.result.lowercased().contains("not logged in") { return .failure(.cliNotLoggedIn) }
                return .failure(.http(0, out.result))
            }
            return .success(())
        } catch let e as ClaudeError {
            return .failure(e)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}
