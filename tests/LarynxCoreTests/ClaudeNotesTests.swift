import Foundation
import Testing
@testable import LarynxCore

/// Meeting notes from Claude, against a stand-in for the Anthropic API (no network, no key, no cost).
private final class StubAPI: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var replies: [(Int, String)] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if let stream = request.httpBodyStream {
            stream.open(); var data = Data(); var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            stream.close(); Self.bodies.append(data)
        } else { Self.bodies.append(request.httpBody ?? Data()) }
        let (status, body) = Self.replies.isEmpty ? (500, "{}") : Self.replies.removeFirst()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func session(_ replies: [(Int, String)]) -> URLSession {
        self.replies = replies; requests = []; bodies = []
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubAPI.self]
        return URLSession(configuration: config)
    }
}

private let meeting = Meeting(id: "t", started: Date(timeIntervalSince1970: 1_800_000_000), duration: 300, segments: [
    MeetingSegment(speaker: "On the call", start: 0, end: 5, text: "The tile is back-ordered for six weeks. I can send photos of two in stock tonight."),
    MeetingSegment(speaker: "You", start: 6, end: 9, text: "Thanks, Priya. Send them tonight and we'll switch if one is close."),
    MeetingSegment(speaker: "On the call", start: 10, end: 14, text: "The budget is sixty two thousand five hundred."),
])

private func reply(_ notes: String, stop: String = "end_turn") -> String {
    let text = String(data: try! JSONSerialization.data(withJSONObject: notes, options: .fragmentsAllowed), encoding: .utf8)!  // a JSON string literal
    return #"{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5-5","stop_reason":"\#(stop)","content":[{"type":"thinking","thinking":""},{"type":"text","text":\#(text)}]}"#
}

private let good = #"{"title":"Renovation schedule","summary":["Priya's tile is back-ordered for six weeks."],"decisions":["Switch tile if one in stock is close."],"actionItems":[{"task":"Send photos of two tiles in stock","owner":"Priya","due":"tonight"},{"task":"Order 900 tiles","owner":"Bob","due":""}],"openQuestions":[]}"#

@Suite(.serialized) struct ClaudeNotesTests {
    @Test func sendsOneWellFormedRequest() async throws {
        let session = StubAPI.session([(200, reply(good))])
        _ = try await ClaudeNotes.write(meeting, key: "test-key", session: session)
        #expect(StubAPI.requests.count == 1)
        let request = try #require(StubAPI.requests.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        let body = try #require(JSONSerialization.jsonObject(with: StubAPI.bodies[0]) as? [String: Any])
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["thinking"] == nil)  // Opus 5.5 thinks adaptively; effort is the control
        let config = try #require(body["output_config"] as? [String: Any])
        #expect(config["effort"] as? String == "high")
        #expect((config["format"] as? [String: Any])?["type"] as? String == "json_schema")
        let user = ((body["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        #expect(user.contains("[00:00] On the call: The tile is back-ordered"))
        #expect(user.contains("about 5 minutes long"))
    }

    @Test func readsTheNotesAndChecksThemAgainstTheTranscript() async throws {
        let notes = try await ClaudeNotes.write(meeting, key: "k", session: StubAPI.session([(200, reply(good))]))
        #expect(notes.title == "Renovation schedule")
        #expect(notes.actionItems.count == 2)
        #expect(notes.actionItems[0].owner == "Priya" && notes.actionItems[0].due == "tonight")
        // verify(): the made-up "900 tiles" item (a number nobody said) is left out; "Bob" was never named.
        let checked = MeetingSummarizer.verify(notes, against: meeting)
        #expect(checked.actionItems.map(\.task) == ["Send photos of two tiles in stock"])
    }

    @Test func retriesWhenBusyThenSucceeds() async throws {
        let session = StubAPI.session([(529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#), (200, reply(good))])
        let notes = try await ClaudeNotes.write(meeting, key: "k", session: session, pause: { _ in })
        #expect(StubAPI.requests.count == 2)
        #expect(notes.title == "Renovation schedule")
    }

    @Test func plainReasonsForTheUsualFailures() async throws {
        await #expect(throws: ClaudeNotes.Failure.noKey) { try await ClaudeNotes.write(meeting, key: nil, session: StubAPI.session([])) }
        await #expect(throws: ClaudeNotes.Failure.badKey) {
            try await ClaudeNotes.write(meeting, key: "k", session: StubAPI.session([(401, #"{"error":{"message":"invalid x-api-key"}}"#)]))
        }
        await #expect(throws: ClaudeNotes.Failure.noCredit) {
            try await ClaudeNotes.write(meeting, key: "k", session: StubAPI.session([(400, #"{"error":{"message":"Your credit balance is too low to access the Anthropic API."}}"#)]))
        }
        await #expect(throws: ClaudeNotes.Failure.refused) {
            try await ClaudeNotes.write(meeting, key: "k", session: StubAPI.session([(200, reply("{}", stop: "refusal"))]))
        }
        await #expect(throws: ClaudeNotes.Failure.cutOff) {
            try await ClaudeNotes.write(meeting, key: "k", session: StubAPI.session([(200, reply("{\"title\":", stop: "max_tokens"))]))
        }
        #expect(ClaudeNotes.Failure.noCredit.description.contains("console.anthropic.com"))
    }

    @Test func autoPicksClaudeOnlyWithAKey() {
        // Tests run without ANTHROPIC_API_KEY and never read the real Keychain (LARYNX_DATA_DIR is set by the test plan
        // or not; either way an explicit model name always wins).
        #expect(MeetingSummarizer.Model.chosen("on-device") == .onDevice)
        #expect(MeetingSummarizer.Model.chosen("claude") == .claude)
    }
}

/// A stand-in for Claude Code: a shell script that saves its arguments, environment and stdin, then prints `reply`.
private func fakeClaudeCode(_ reply: String) throws -> (binary: URL, dir: URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("larynx-fake-claude-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(reply.utf8).write(to: dir.appendingPathComponent("reply.json"))
    let script = """
        #!/bin/sh
        d="\(dir.path)"
        for a in "$@"; do printf '%s\\n' "$a"; done > "$d/args.txt"
        env > "$d/env.txt"
        pwd > "$d/pwd.txt"
        cat > "$d/stdin.txt"
        cat "$d/reply.json"
        """
    let binary = dir.appendingPathComponent("claude")
    try Data(script.utf8).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    return (binary, dir)
}

@Suite(.serialized) struct ClaudeCodeNotesTests {
    @Test func notesComeBackFromClaudeCodeWithNoToolsAndNoKey() async throws {
        let notes = try JSONSerialization.jsonObject(with: Data(good.utf8))
        let reply = String(decoding: try JSONSerialization.data(withJSONObject: ["type": "result", "subtype": "success", "is_error": false,
                                                                                 "result": good, "structured_output": notes]), as: UTF8.self)
        let (binary, dir) = try fakeClaudeCode(reply)
        defer { try? FileManager.default.removeItem(at: dir) }
        setenv("ANTHROPIC_API_KEY", "should-not-reach-claude-code", 1)
        defer { unsetenv("ANTHROPIC_API_KEY") }
        let out = try await ClaudeCode.write(meeting, binary: binary)
        #expect(out.title == "Renovation schedule")
        #expect(out.actionItems.first?.owner == "Priya")
        let args = try String(contentsOf: dir.appendingPathComponent("args.txt"), encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(args.first == "-p")
        #expect(args.contains("--json-schema") && args.contains("--strict-mcp-config") && args.contains("--no-session-persistence"))
        let tools = try #require(args.firstIndex(of: "--tools"))
        #expect(args[tools + 1] == "")  // no tools at all
        let sources = try #require(args.firstIndex(of: "--setting-sources"))
        #expect(args[sources + 1] == "")  // none of the person's settings or hooks
        #expect(args[try #require(args.firstIndex(of: "--model")) + 1] == "opus")
        let env = try String(contentsOf: dir.appendingPathComponent("env.txt"), encoding: .utf8)
        #expect(!env.contains("ANTHROPIC_API_KEY"))  // or Claude Code would bill the key instead of the plan
        let stdin = try String(contentsOf: dir.appendingPathComponent("stdin.txt"), encoding: .utf8)
        #expect(stdin.contains("back-ordered for six weeks") && stdin.contains("<transcript>"))
        let pwd = try String(contentsOf: dir.appendingPathComponent("pwd.txt"), encoding: .utf8)
        #expect(pwd.contains("larynx-notes-"))  // an empty folder, no project files
    }

    @Test func theChosenModelReachesClaudeCodeAndTheAPI() throws {
        defer { ClaudeNotes.choiceOverride = nil }
        for (choice, alias, id) in [("opus", "opus", "claude-opus-5-5"), ("sonnet", "sonnet", "claude-sonnet-5-5")] {
            ClaudeNotes.choiceOverride = choice
            let args = try ClaudeCode.arguments(system: "x")
            let i = try #require(args.firstIndex(of: "--model"))
            #expect(args[i + 1] == alias)
            #expect(ClaudeNotes.model == id)
        }
    }

    @Test func notSignedInSaysHowToSignIn() async throws {
        let (binary, dir) = try fakeClaudeCode(#"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: ClaudeCode.Failure.notSignedIn) { try await ClaudeCode.write(meeting, binary: binary) }
        #expect(ClaudeCode.Failure.notSignedIn.description.contains("sign in"))
    }

    @Test func missingClaudeCodeIsSaidPlainly() async throws {
        await #expect(throws: ClaudeCode.Failure.notInstalled) { try await ClaudeCode.write(meeting, binary: nil) }
    }
}
