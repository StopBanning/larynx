import AppKit
import AVFoundation
import Foundation
import LarynxCore

// MARK: - Options

let args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let modelsDir: URL? = option("--models-dir").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    ?? (Bundle.main.bundleURL.pathExtension == "app"
        ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Larynx/models", isDirectory: true)
        : nil)
let wantsClean = args.contains("--clean")  // always rewrite
/// AI rewrite policy: `--rewrite auto|off`, else `defaults write com.automatedworkflow.larynx rewrite auto`. Auto rewrites only when a trigger fires.
var autoRewrite: Bool { (option("--rewrite") ?? Settings.shared.string(.rewrite)) == "auto" }
let verbatim = args.contains("--verbatim")

let usage = """
    larynx: local, offline dictation for macOS (Parakeet TDT v3 on the Neural Engine)

    larynx transcribe <audio file> [--clean]   print the transcript of a file
    larynx listen [--key fn|rightOption|rightCommand|rightControl] [--clean]
                                              hold the key, speak, release: text pastes where your cursor is
    larynx history [--search words] [--json]   your recent dictations (kept on this Mac, 30 days by default)
    larynx recover                             transcribe recordings a crash left behind
    larynx mine [--log <file>] [--apply]       find words you fixed by saying them again, and learn them
    larynx serve                               JSON lines on stdin/stdout, for apps such as Locust (see docs/INTEGRATION.md)
    larynx mcp                                 MCP server for agents (transcribe_file, clean_text, add_dictionary_word, status)

    --models-dir <path>   where the speech model lives (downloaded once, about 500 MB)
    --engine parakeet|clean   clean = English-only model that drops ums, false starts and repeats
    --mode ai|correspondence|standard   how much to polish (listen picks it from the front app)
    --verbatim            skip the tidy-up rules
    --rewrite auto|off    AI rewrite for corrections, numbers and verbal tics, only when needed (Apple's on-device model)
    --clean               always run the AI rewrite with Apple's on-device model when available
    """

// MARK: - Output

let outLock = NSLock()

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
    outLock.lock(); defer { outLock.unlock() }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("larynx: \(message)\n".utf8))
}

func ms(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

func runTranscribe() async {
    guard args.count >= 2 else { print(usage); exit(2) }
    do {
        let samples = try loadAudioFile(URL(fileURLWithPath: args[1]))
        let loadStart = Date()
        try await Loader.shared.task.value
        log("model ready in \(ms(since: loadStart)) ms")
        let result = try await finish(samples, clean: wantsClean, mode: option("--mode").flatMap(CleanupMode.init(rawValue:)) ?? .standard)
        log("\(result.audioSeconds) s of audio, speech \(result.asrMs) ms, total \(result.totalMs) ms")
        print(result.text)
        exit(0)
    } catch {
        log("\(error)"); exit(1)
    }
}

func runCommand() {
switch args.first {
case "transcribe": Task { await runTranscribe() }
case "listen":
    if let feed = option("--feed") { Task { await runFeed(feed) } } else { Task { await runListen(keys: listenKeys) } }
case "history":
    // larynx history [--search words] [--limit n] [--json]
    let limit = Int(option("--limit") ?? "") ?? 20
    let rows = option("--search").map { History.shared.search($0, limit: limit) } ?? History.shared.recent(limit: limit)
    if args.contains("--json") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: (try? encoder.encode(rows)) ?? Data("[]".utf8), as: UTF8.self))
    } else if rows.isEmpty {
        print(Settings.shared.string(.history) == "off" ? "History is off (history: off in settings.json)." : "No dictations found.")
    } else {
        let f = DateFormatter(); f.dateFormat = "MMM d HH:mm"
        for r in rows {
            let mark = r.flags.contains("recovered") ? " [recovered]" : ""
            print("\(f.string(from: r.time))  \(r.app ?? "?")\(mark)\n  \(r.text)")
        }
    }
    exit(0)
case "mine":
    // Finds repeats with a word fixed in your history (and, with --log, in old Larynx.log lines that still have
    // text) and prints what would be learned. --apply saves the safe lessons. larynx mine [--log path] [--apply]
    Task { @MainActor in
        var items: [(text: String, app: String?, time: Date)] = History.shared.recent(limit: 5000).reversed().map { ($0.text, $0.app, $0.time) }
        if let path = option("--log") {
            let re = try! NSRegularExpression(pattern: #"^larynx: \d+ ms \[\w+ ([^\]]*)\] [a-z+]+, rewrite: .*? \(\d+ ms\): (.+)$"#)
            let lines = ((try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8)) ?? "").split(separator: "\n")
            // Old lines have no timestamps: treat neighbours as 30 s apart so each is compared with the one before it.
            var t = Date.distantPast
            for line in lines {
                let s = String(line)
                guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                      let app = Range(m.range(at: 1), in: s), let text = Range(m.range(at: 2), in: s) else { continue }
                t = t.addingTimeInterval(30)
                items.insert((String(s[text]), String(s[app]), t), at: 0)
            }
            items.sort { $0.time < $1.time }
        }
        var found: [Corrections.Lesson] = []
        for (a, b) in zip(items, items.dropFirst()) where a.app == b.app && b.time.timeIntervalSince(a.time) <= Relearn.window {
            for lesson in Corrections.lessons(Corrections.changes(previous: a.text, current: b.text), words: MacWordList()) where !found.contains(lesson) {
                found.append(lesson)
            }
        }
        for lesson in found {
            switch lesson {
            case .dictionary(let h, let m): print("dictionary  \(h) -> \(m)")
            case .vocabulary(let w): print("vocabulary  \(w)")
            case .suggestion(let h, let m): print("suggestion  \(h) -> \(m)   (real words: not learned automatically)")
            }
        }
        if found.isEmpty { print("Nothing to learn yet.") }
        if args.contains("--apply") {
            let applied = Relearn.apply(found)
            print("applied: \(applied.isEmpty ? "nothing new" : Relearn.describe(applied))")
        }
        exit(0)
    }
case "recover":
    // Transcribes anything a crash left in the spool, as the app does at launch: larynx recover [--json]
    Task {
        let rows = await recoverAbandoned(before: launchedAt)
        if args.contains("--json") {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
            print(String(decoding: (try? encoder.encode(rows)) ?? Data("[]".utf8), as: UTF8.self))
        } else {
            print(rows.isEmpty ? "Nothing to recover." : rows.map { "recovered \($0.id): \($0.text)" }.joined(separator: "\n"))
        }
        exit(0)
    }
case "serve": Task { await runServe() }
case "mcp": Task { await runMCP() }
case "focus":
    // What has focus in the front app, after an optional delay: larynx focus [seconds]. Needs Accessibility.
    let wait = Double(args.dropFirst().first ?? "") ?? 0
    Thread.sleep(forTimeInterval: wait)
    let app = NSWorkspace.shared.frontmostApplication
    let f = Inserter.focusedField(in: app)
    let readable = Learner.focusedTextElement(in: app).flatMap { Learner.text(of: $0) }
    print("\(app?.bundleIdentifier ?? "?"): editable=\(f.editable.map(String.init) ?? "unknown") role=\(f.role) "
          + "text readable=\(readable.map { "yes (\($0.count) chars)" } ?? "no")")
    exit(0)
case "fixes":
    // What Larynx would learn if you pasted <before> and the field later said <after> (nothing is saved).
    guard args.count >= 3 else { print("larynx fixes <pasted> <field now>"); exit(2) }
    let found = Learner.fixes(pasted: args[1], now: args[2])
    print(found.isEmpty ? "nothing to learn" : found.map { "\($0.heard) -> \($0.fixed)" }.joined(separator: ", "))
    exit(0)
case "vocab":
    // The words Larynx listens for, and where they come from.
    Vocabulary.ensureExists()
    print(Vocabulary.terms().joined(separator: "\n"))
    log("edit \(Vocabulary.url.path); project names come from \(Vocabulary.roots.map(\.path).joined(separator: ", "))")
    exit(0)
case "pill-demo":
    // Plays the pill's states with a synthetic voice so they can be watched or screenshotted (holding the talk key
    // while pressing a screenshot shortcut cancels the dictation). larynx pill-demo [seconds] [text]
    let seconds = Double(args.dropFirst().first ?? "") ?? 12
    let sample = args.count > 2 ? args[2] : "I wanna add you on my schedule for Wednesday, and can you send the report before the meeting starts on Friday afternoon?"
    NSApplication.shared.setActivationPolicy(.accessory)
    Task { @MainActor in
        let started = Date()
        // Speech-like loudness: syllables (~5 Hz) inside phrases (~0.4 Hz), with short pauses.
        let level: () -> Float = {
            let t = Date().timeIntervalSince(started)
            let syllable = (sin(t * 2 * .pi * 4.7) + 1) / 2, phrase = max(0, sin(t * 2 * .pi * 0.38) + 0.35)
            return Float(0.004 + 0.12 * syllable * min(1, phrase) + Double.random(in: 0...0.015))
        }
        let front = NSWorkspace.shared.frontmostApplication
        Pill.shared.listen(app: front, privateField: false, field: Inserter.focusedFieldFrame(in: front), level: level)
        log("pill window \(Pill.shared.windowNumber ?? -1)")
        let words = sample.split(separator: " ")
        let speaking = seconds * 0.7
        var shown = 0
        while Date().timeIntervalSince(started) < speaking {
            try? await Task.sleep(nanoseconds: 300_000_000)
            let due = Int(Double(words.count) * min(1, (Date().timeIntervalSince(started) - 0.8) / (speaking - 1)))
            if due > shown { shown = due; Pill.shared.words(words.prefix(shown).joined(separator: " ")) }
        }
        log("pill frame words \(Pill.shared.frame.map { NSStringFromRect($0) } ?? "-")")
        Pill.shared.transcribing()
        try? await Task.sleep(nanoseconds: UInt64(seconds * 0.2 * 1_000_000_000))
        Pill.shared.message("Copied: press ⌘V to paste", symbol: "doc.on.clipboard", tint: .systemOrange)
        try? await Task.sleep(nanoseconds: UInt64(seconds * 0.1 * 1_000_000_000))
        Pill.shared.hide()
        try? await Task.sleep(nanoseconds: 300_000_000)
        exit(0)
    }
    NSApplication.shared.run()
case "rewrite":
    // Text in, tidied and (if triggered) rewritten text out; the decision goes to stderr.
    let mode = option("--mode").flatMap(CleanupMode.init(rawValue:)) ?? .correspondence
    let input = args.last ?? ""
    Task {
        let started = Date()
        let outcome = await Cleaner.rewrite(Tidy.apply(input, mode: mode), mode: mode, force: wantsClean)
        log("\(outcome.used ? "rewrote" : "kept") in \(ms(since: started)) ms: \(outcome.note)")
        print(outcome.text); exit(0)
    }
case "tidy":
    let mode = option("--mode").flatMap(CleanupMode.init(rawValue:)) ?? .standard
    print(Tidy.apply(args.last ?? "", mode: mode)); exit(0)
default: print(usage); exit(args.isEmpty || args.first == "--help" || args.first == "-h" ? 0 : 2)
}
}

/// `larynx listen --feed <audio>`: one dictation from a file through the listen path's spool, pipeline and history,
/// with no microphone, key or paste. Prints the result as JSON. `LARYNX_TEST_DELAY_MS` waits between spooling and
/// transcription, so a test can kill the process mid-dictation and check that the next launch recovers it.
func runFeed(_ path: String) async {
    do {
        let samples = try loadAudioFile(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        let mode = option("--mode").flatMap(CleanupMode.init(rawValue:)) ?? .standard
        let pending = History.shared.begin(samples: samples, app: nil, mode: mode, privateField: false)
        emit(["event": "spooled", "id": pending.id, "saved": pending.persists])
        if let delay = Int(ProcessInfo.processInfo.environment["LARYNX_TEST_DELAY_MS"] ?? "") {
            try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
        }
        let result = try await finish(samples, clean: wantsClean, mode: mode)
        if result.text.isEmpty { History.shared.discard(pending) }
        else { History.shared.complete(pending, transcript: result, delivery: "none") }
        var body = try result.jsonObject()
        body["event"] = "result"
        body["id"] = pending.id
        emit(body)
        exit(0)
    } catch {
        log("\(error)"); exit(1)
    }
}
