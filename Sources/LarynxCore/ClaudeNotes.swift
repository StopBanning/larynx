import Foundation
import Security

/// Writes a meeting's notes with Claude through the Anthropic API (docs/dev/MEETING.md, "Claude writes the notes").
/// The audio and the transcript are made on the computer; only the finished transcript is sent, for the notes. One
/// request reads the whole meeting (Claude's context is far larger than any meeting), and structured output returns
/// the notes in a fixed shape, so the layout never breaks. Swift has no official SDK, so this is the plain HTTP API.
public enum ClaudeNotes {
    public static let model = "claude-opus-5-5"
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

    /// The request body for one meeting (kept separate so tests can check it without a network).
    static func body(for meeting: Meeting) throws -> Data {
        let names = meeting.addressedNames
        let system = MeetingSummarizer.instructions + "\n" + MeetingSummarizer.legend
            + (names.isEmpty ? "" : "\nNames said in this meeting: \(names.joined(separator: ", ")).")
            + "\nWrite in plain words a 75-year-old would read without effort. Keep every number with its unit, exactly as said."
        let formatter = DateFormatter(); formatter.dateStyle = .full; formatter.timeStyle = .short
        let minutes = max(1, Int((meeting.duration / 60).rounded()))
        let transcript = meeting.segments.map { "[\(Meeting.clock($0.start))] \($0.speaker): \($0.text)" }.joined(separator: "\n")
        let user = "A meeting on \(formatter.string(from: meeting.started)), about \(minutes) minute\(minutes == 1 ? "" : "s") long.\n\n<transcript>\n\(transcript)\n</transcript>"
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
