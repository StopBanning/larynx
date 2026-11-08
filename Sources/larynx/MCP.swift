import Foundation
import LarynxCore

/// `larynx mcp`: a Model Context Protocol server on stdin/stdout (JSON-RPC 2.0, one message per line),
/// so agents such as Claude Code can transcribe audio files and clean up text with Larynx.
func runMCP() async {
    let tools: [[String: Any]] = [
        ["name": "transcribe_file",
         "description": "Transcribe an audio file (wav, m4a, mp3, aiff...) on-device and clean it up. Returns the text.",
         "inputSchema": ["type": "object", "required": ["path"], "properties": [
            "path": ["type": "string", "description": "Absolute path to the audio file"],
            "mode": ["type": "string", "enum": ["ai", "correspondence", "standard"], "description": "How much to polish (default standard)"],
         ]]],
        ["name": "clean_text",
         "description": "Clean up dictated text: dictionary fixes, filler and stutter removal, and (when needed) an on-device AI pass for self-corrections, numbers and verbal tics.",
         "inputSchema": ["type": "object", "required": ["text"], "properties": [
            "text": ["type": "string"],
            "mode": ["type": "string", "enum": ["ai", "correspondence", "standard"], "description": "Default correspondence"],
         ]]],
        ["name": "add_dictionary_word",
         "description": "Teach Larynx a word it keeps mishearing, e.g. heard 'lynx' -> written 'Larynx'.",
         "inputSchema": ["type": "object", "required": ["heard", "written"], "properties": [
            "heard": ["type": "string"], "written": ["type": "string"],
         ]]],
        ["name": "status",
         "description": "Which speech model Larynx uses, whether the AI rewrite is available, and the dictionary size.",
         "inputSchema": ["type": "object", "properties": [:] as [String: Any]]],
    ]

    func send(_ object: [String: Any]) { emit(object) }
    func result(_ id: Any, _ body: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": body]) }
    func text(_ id: Any, _ s: String, error: Bool = false) {
        result(id, ["content": [["type": "text", "text": s]], "isError": error])
    }

    while let line = readLine() {
        guard let data = line.data(using: .utf8),
              let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let method = msg["method"] as? String
        else { continue }
        guard let id = msg["id"] else { continue }  // notifications (initialized, cancelled) need no reply
        let params = msg["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            result(id, ["protocolVersion": (params["protocolVersion"] as? String) ?? "2025-06-18",
                        "capabilities": ["tools": [:] as [String: Any]],
                        "serverInfo": ["name": "larynx", "version": "0.3.0"]])
        case "ping":
            result(id, [:])
        case "tools/list":
            result(id, ["tools": tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let a = params["arguments"] as? [String: Any] ?? [:]
            switch name {
            case "transcribe_file":
                guard let path = a["path"] as? String else { text(id, "path is required", error: true); continue }
                do {
                    let samples = try loadAudioFile(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
                    let r = try await finish(samples, clean: false,
                                             mode: (a["mode"] as? String).flatMap(CleanupMode.init(rawValue:)) ?? .standard)
                    text(id, r["text"] as? String ?? "")
                } catch { text(id, "\(error)", error: true) }
            case "clean_text":
                let mode = (a["mode"] as? String).flatMap(CleanupMode.init(rawValue:)) ?? .correspondence
                let tidied = Tidy.apply(Dictionary.apply(a["text"] as? String ?? ""), mode: mode)
                text(id, await Cleaner.rewrite(tidied, mode: mode).text)
            case "add_dictionary_word":
                guard let heard = a["heard"] as? String, let written = a["written"] as? String, !heard.isEmpty
                else { text(id, "heard and written are required", error: true); continue }
                do { try Dictionary.add(heard: heard, written: written); text(id, "Added: \(heard) -> \(written)") }
                catch { text(id, "\(error)", error: true) }
            case "status":
                text(id, "model: \(engine.modelName); AI rewrite available: \(Cleaner.isAvailable); dictionary entries: \(Dictionary.load().count)")
            default:
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "unknown tool \(name)"]])
            }
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "method not found: \(method)"]])
        }
    }
    exit(0)
}
