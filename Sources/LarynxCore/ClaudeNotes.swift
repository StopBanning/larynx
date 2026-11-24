import Foundation
import Security

/// Writes a meeting's notes with Claude through the Anthropic API (docs/MEETINGS.md, "Claude writes the notes").
/// The audio and the transcript are made on the computer; only the finished transcript is sent, for the notes. One
/// request reads the whole meeting (Claude's context is far larger than any meeting), and structured output returns
/// the notes in a fixed shape, so the layout never breaks. Swift has no official SDK, so this is the plain HTTP API.
public enum ClaudeNotes {
    /// Which Claude writes the notes (`meetingClaude`): "sonnet" or "opus". `larynx meeting --claude` overrides it.
    nonisolated(unsafe) public static var choiceOverride: String?
    public static var choice: String { choiceOverride ?? Settings.shared.string(.meetingClaude) }
    public static var model: String { choice == "sonnet" ? "claude-sonnet-5-5" : "claude-opus-5-5" }
    static let version = "2026-10-21"
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case noKey, badKey, noCredit, unreachable(String), refused, cutOff, malformed(String), api(Int, String)
        public var description: String {
            switch self {
            case .noKey: return "There's no Claude key yet. Add one in Settings → Meetings."
            case .badKey: return "The Claude key wasn't accepted. Check it in Settings → Meetings."
            case .noCredit: return "The Anthropic account is out of credit. Add credit at console.anthropic.com."
            case .unreachable(let why): return "Couldn't reach Claude (\(why)). Check the internet connection."
            case .refused: return "Claude declined to write notes for this meeting."
            case .cutOff: return "Claude's notes came back cut off."
            case .malformed(let why): return "Claude's notes came back in an unexpected shape (\(why))."
            case .api(let status, let message): return "Claude returned an error (\(status)): \(message)"
            }
        }
    }

    static let schema: [String: Any] = {
        func list(_ about: String) -> [String: Any] { ["type": "array", "description": about, "items": ["type": "string"]] }
        let item: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["task", "owner", "due"],
            "properties": [
                "task": ["type": "string", "description": "What will be done, as a short sentence."],
                "owner": ["type": "string", "description": "Who will do it, only if said; otherwise empty."],
                "due": ["type": "string", "description": "When, in the words used (\"Friday\", \"tonight\"), only if said; otherwise empty."],
            ],
        ]
        return [
            "type": "object", "additionalProperties": false,
            "required": ["title", "summary", "decisions", "actionItems", "openQuestions"],
            "properties": [
                "title": ["type": "string", "description": "A short title for the meeting, three to seven words."],
                "summary": list("Three to five short sentences: what the meeting was about and what came of it."),
                "decisions": list("Each decision as a short sentence. Empty if nothing was decided."),
                "actionItems": ["type": "array", "items": item],
                "openQuestions": list("Things raised and left unanswered. Empty if none."),
            ],
        ]
    }()

    /// The instructions and the transcript for one meeting, the same for the API and for Claude Code.
    static func prompt(for meeting: Meeting) -> (system: String, user: String) {
        let names = meeting.addressedNames
        let system = MeetingSummarizer.instructions + "\n" + MeetingSummarizer.legend
            + (MeetingSummarizer.listeningNote(meeting).map { "\n" + $0 } ?? "")
            + (names.isEmpty ? "" : "\nNames said in this meeting: \(names.joined(separator: ", ")).")
            + "\nWrite in plain words a 75-year-old would read without effort. Keep every number with its unit, exactly as said."
        let formatter = DateFormatter(); formatter.dateStyle = .full; formatter.timeStyle = .short
        let minutes = max(1, Int((meeting.duration / 60).rounded()))
        let transcript = meeting.segments.map { "[\(Meeting.clock($0.start))] \($0.speaker): \($0.text)" }.joined(separator: "\n")
        let user = "A meeting on \(formatter.string(from: meeting.started)), about \(minutes) minute\(minutes == 1 ? "" : "s") long.\n\n<transcript>\n\(transcript)\n</transcript>"
        return (system, user)
    }

    /// The request body for one meeting (kept separate so tests can check it without a network).
    static func body(for meeting: Meeting) throws -> Data {
        let (system, user) = prompt(for: meeting)
        let json: [String: Any] = [
            "model": model,
            "max_tokens": 16_000,
            "fallbacks": "default",
            "output_config": ["effort": "high", "format": ["type": "json_schema", "schema": schema]],
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    static func endpoint() -> URL {
        let base = ProcessInfo.processInfo.environment["LARYNX_CLAUDE_URL"] ?? "https://api.anthropic.com"
        return URL(string: base.hasSuffix("/") ? String(base.dropLast()) : base)!.appendingPathComponent("v1/messages")
    }

    /// Notes for one meeting. Retries twice on a busy or unreachable server, then gives up with a plain reason.
    static func write(_ meeting: Meeting, key: String? = ClaudeKey.read(), session: URLSession = .shared,
                             pause: @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) async throws -> GeneratedNotes {
        guard let key, !key.isEmpty else { throw Failure.noKey }
        var request = URLRequest(url: endpoint(), timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(version, forHTTPHeaderField: "anthropic-version")
        request.setValue(fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try body(for: meeting)
        var attempt = 0
        while true {
            attempt += 1
            let data: Data, response: URLResponse
            do { (data, response) = try await session.data(for: request) }
            catch {
                if attempt < 3 { await pause(Double(attempt * attempt) * 2); continue }
                throw Failure.unreachable((error as NSError).localizedDescription)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return try parse(data) }
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }.flatMap { $0["message"] as? String } ?? String(decoding: data.prefix(300), as: UTF8.self)
            switch status {
            case 401, 403: throw Failure.badKey
            case 400 where message.lowercased().contains("credit balance"): throw Failure.noCredit
            case 408, 409, 429, 500...599 where attempt < 3:
                let wait = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? Double(attempt * attempt) * 2
                await pause(min(wait, 30)); continue
            default: throw Failure.api(status, message)
            }
        }
    }

    static func parse(_ data: Data) throws -> GeneratedNotes {
        guard let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.malformed("not JSON") }
        switch reply["stop_reason"] as? String {
        case "refusal": throw Failure.refused
        case "max_tokens": throw Failure.cutOff
        default: break
        }
        let blocks = reply["content"] as? [[String: Any]] ?? []
        guard let text = blocks.last(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let notes = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { throw Failure.malformed("no notes in the reply") }
        return self.notes(from: notes)
    }

    static func notes(from notes: [String: Any]) -> GeneratedNotes {
        func strings(_ key: String) -> [String] {
            (notes[key] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        let items = (notes["actionItems"] as? [[String: Any]] ?? []).compactMap { item -> GeneratedNotes.Item? in
            let task = (item["task"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return task.isEmpty ? nil : GeneratedNotes.Item(task: task, owner: item["owner"] as? String ?? "", due: item["due"] as? String ?? "")
        }
        return GeneratedNotes(title: (notes["title"] as? String).flatMap(\.nilIfBlank) ?? "Meeting", summary: strings("summary"),
                              decisions: strings("decisions"), actionItems: items, openQuestions: strings("openQuestions"))
    }
}

/// Meeting notes through Claude Code, signed in to the person's own Claude plan: no API key and no extra bill. Runs
/// `claude -p` with no tools, no MCP servers and none of the person's settings or hooks, the transcript on stdin and the
/// notes' shape as a JSON schema. `ANTHROPIC_API_KEY` is taken out of its environment, or Claude Code would bill that
/// key instead of the plan.
public enum ClaudeCode {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case notInstalled, notSignedIn, failed(String)
        public var description: String {
            switch self {
            case .notInstalled: return "Claude Code isn't installed on this Mac."
            case .notSignedIn: return "Claude Code isn't signed in. Open Terminal, type claude, and sign in with your Claude account."
            case .failed(let why) where why.lowercased().contains("limit"):
                return "Your Claude plan's limit was reached (\(why)). Write the notes again once it resets."
            case .failed(let why): return "Claude Code couldn't write the notes (\(why))."
            }
        }
    }

    /// Where Claude Code is. A Mac app doesn't get the shell's PATH, so the usual install places are checked by name.
    /// `LARYNX_CLAUDE_CODE` names it for tests; tests never find the real one.
    public static func find() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let path = env["LARYNX_CLAUDE_CODE"] { return path.isEmpty ? nil : URL(fileURLWithPath: path) }
        if env["LARYNX_DATA_DIR"] != nil { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let places = ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin",
                      "\(home)/.bun/bin"] + (env["PATH"] ?? "").split(separator: ":").map(String.init)
        return places.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent("claude") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static var isInstalled: Bool { find() != nil }

    static func arguments(system: String) throws -> [String] {
        let schema = String(decoding: try JSONSerialization.data(withJSONObject: ClaudeNotes.schema, options: [.sortedKeys]), as: UTF8.self)
        return ["-p", "--output-format", "json", "--json-schema", schema, "--model", ClaudeNotes.choice == "sonnet" ? "sonnet" : "opus", "--tools", "",
                "--strict-mcp-config", "--setting-sources", "", "--no-session-persistence", "--system-prompt", system]
    }

    static func write(_ meeting: Meeting, binary: URL? = find(), timeout: TimeInterval = 600) async throws -> GeneratedNotes {
        guard let binary else { throw Failure.notInstalled }
        let (system, user) = ClaudeNotes.prompt(for: meeting)
        let args = try arguments(system: system)
        let output: Data = try await withCheckedThrowingContinuation { done in
            DispatchQueue.global().async {
                do { done.resume(returning: try run(binary, args, input: Data(user.utf8), timeout: timeout)) }
                catch { done.resume(throwing: error) }
            }
        }
        return try parse(output)
    }

    static func run(_ binary: URL, _ args: [String], input: Data, timeout: TimeInterval) throws -> Data {
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"] { env[key] = nil }
        env["PATH"] = binary.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        process.environment = env
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("larynx-notes-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        process.currentDirectoryURL = dir  // an empty folder: no project files, no CLAUDE.md
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        do { try process.run() } catch { throw Failure.failed(error.localizedDescription) }
        var out = Data(), err = Data()
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { out = stdout.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { err = stderr.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw Failure.failed("it took longer than \(Int(timeout / 60)) minutes")
        }
        process.waitUntilExit()
        if out.isEmpty {
            let why = String(decoding: err.prefix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if why.lowercased().contains("log in") || why.lowercased().contains("login") || why.lowercased().contains("not logged") { throw Failure.notSignedIn }
            throw Failure.failed(why.isEmpty ? "exit \(process.terminationStatus)" : why)
        }
        return out
    }

    static func parse(_ data: Data) throws -> GeneratedNotes {
        guard let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let text = String(decoding: data.prefix(400), as: UTF8.self)
            if text.lowercased().contains("log in") || text.lowercased().contains("not logged") { throw Failure.notSignedIn }
            throw Failure.failed("its reply wasn't JSON")
        }
        if reply["is_error"] as? Bool == true {
            let why = (reply["result"] as? String ?? reply["subtype"] as? String ?? "error")
            let lower = why.lowercased()
            if lower.contains("log in") || lower.contains("login") || lower.contains("not logged") || lower.contains("authenticat") { throw Failure.notSignedIn }
            throw Failure.failed(String(why.prefix(300)))
        }
        if let notes = reply["structured_output"] as? [String: Any] { return ClaudeNotes.notes(from: notes) }
        if let text = reply["result"] as? String, let notes = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
            return ClaudeNotes.notes(from: notes)
        }
        throw Failure.failed("no notes in its reply")
    }
}

/// The Anthropic API key for meeting notes. Kept in the Mac's Keychain (never in settings.json or the history), so it
/// stays on this Mac. `ANTHROPIC_API_KEY` in the environment wins, for the command line and tests.
public enum ClaudeKey {
    static let service = "com.automatedworkflow.larynx.claude"
    static let account = "anthropic-api-key"

    public static func read() -> String? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty { return env }
        if ProcessInfo.processInfo.environment["LARYNX_DATA_DIR"] != nil { return nil }  // tests never read the real Keychain
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var found: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static var isSet: Bool { read() != nil }

    @discardableResult
    public static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return remove() }
        remove()
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecValueData as String: Data(trimmed.utf8),
                                   kSecAttrLabel as String: "Larynx: Claude key for meeting notes",
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public static func remove() -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
