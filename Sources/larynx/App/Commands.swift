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
    larynx review [--hours 24] [--text]        the daily read: speed, deliveries, doubtful, fixes, shadow proposals
    larynx golden list|add <id>|candidates     your recordings with what you really said, the benchmark (bench/run.py --sets golden)
    larynx serve                               JSON lines on stdin/stdout, for apps such as Locust (see docs/INTEGRATION.md)
    larynx mcp                                 MCP server for agents (transcribe_file, clean_text, add_dictionary_word, status)

    --models-dir <path>   where the speech model lives (downloaded once, about 500 MB)
    --engine clean|parakeet|bark3|ultra|unified   speech model (clean = English, drops ums; see docs/BENCHMARKS.md)
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
        // --words: what the model heard with its confidence per word (for calibrating doubt), then exit.
        // Several files: every audio path among the arguments, one line each ("path<TAB>confidence<TAB>words").
        if args.contains("--words") {
            let files = args.dropFirst().filter { ["wav", "flac", "m4a", "aiff", "mp3"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) && FileManager.default.fileExists(atPath: $0) }
            for file in files {
                let heard = try await transcriber.transcribeDetailed(try loadAudioFile(URL(fileURLWithPath: file)))
                let words = heard.words.map { $0.word + String(format: ":%.2f", $0.confidence) }.joined(separator: " ")
                print(files.count > 1 ? "\(file)\t\(String(format: "%.3f", heard.confidence))\t\(words)" : String(format: "%.3f", heard.confidence) + "  " + words)
            }
            exit(0)
        }
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
case "mine" where args.contains("--shadow"):
    // What shadowed stages and shadow rules would have changed, newest first. larynx mine --shadow [stage] [--limit n]
    // Stages: tidy, numbers, rewrite... (set "stages.<name>": "shadow" in settings.json); rules: shadow:<name>.
    let wanted = option("--shadow").flatMap { $0.hasPrefix("--") ? nil : $0 }
    var counts: [String: Int] = [:]
    var shown = 0
    let limit = Int(option("--limit") ?? "") ?? 50
    for row in History.shared.recent(limit: 5000) {
        for step in row.steps where !step.applied && step.before != step.after {
            counts[step.stage, default: 0] += 1
            guard let wanted, step.stage == wanted || step.stage == "shadow:" + wanted, shown < limit else { continue }
            shown += 1
            print("\(row.id)  [\(step.stage)]\n   now:   \(step.before)\n   would: \(step.after)")
        }
    }
    if counts.isEmpty { print("No shadow proposals in history.") }
    for (stage, n) in counts.sorted(by: { $0.key < $1.key }) { print("\(stage): \(n) dictation\(n == 1 ? "" : "s") would change") }
    if wanted == nil, !counts.isEmpty { print("larynx mine --shadow <stage> lists them") }
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
        for (a, b) in zip(items, items.dropFirst()) where a.app == b.app && b.time.timeIntervalSince(a.time) <= 90 {  // Relearn.window
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
        // LARYNX_DEMO_BACKDROP=1: colour stripes behind the pill, to see (and screenshot) what the glass does.
        if ["1", "dark"].contains(ProcessInfo.processInfo.environment["LARYNX_DEMO_BACKDROP"] ?? ""), let area = NSScreen.main?.visibleFrame {
            let frame = NSRect(x: area.midX - 380, y: area.minY + 20, width: 760, height: 200)
            let backdrop = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            backdrop.level = .floating
            backdrop.ignoresMouseEvents = true
            let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
            view.wantsLayer = true
            let stripes = CAGradientLayer()
            stripes.frame = view.bounds
            stripes.startPoint = CGPoint(x: 0, y: 0.5); stripes.endPoint = CGPoint(x: 1, y: 0.5)
            stripes.colors = [NSColor.systemPink, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue, .systemPurple].map(\.cgColor)
            // LARYNX_DEMO_BACKDROP=dark: a near-black window like a dark-mode chat app instead.
            if ProcessInfo.processInfo.environment["LARYNX_DEMO_BACKDROP"] == "dark" {
                stripes.colors = [NSColor(white: 0.13, alpha: 1).cgColor, NSColor(white: 0.13, alpha: 1).cgColor]
            }
            view.layer?.addSublayer(stripes)
            let text = NSTextField(labelWithString: "Larynx Larynx Larynx Larynx Larynx Larynx")
            text.font = .systemFont(ofSize: 44, weight: .heavy)
            text.textColor = .white
            text.frame = NSRect(x: 10, y: 60, width: 740, height: 60)
            view.addSubview(text)
            backdrop.contentView = view
            backdrop.orderFrontRegardless()
        }
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
    // Text in, through tidy, numbers and (if triggered) the rewrite, as in the pipeline; the decision goes to stderr.
    let mode = option("--mode").flatMap(CleanupMode.init(rawValue:)) ?? .correspondence
    let input = args.last ?? ""
    Task {
        let started = Date()
        let outcome = await Cleaner.rewrite(Numbers.apply(Tidy.apply(input, mode: mode)), mode: mode, force: wantsClean)
        log("\(outcome.used ? "rewrote" : "kept") in \(ms(since: started)) ms: \(outcome.note)")
        print(outcome.text); exit(0)
    }
case "numbers":
    // Spoken numbers to digits, for testing: larynx numbers "<text>", or lines on stdin (prints only lines it changes).
    if args.count >= 2 { print(Numbers.apply(args[1])); exit(0) }
    while let line = readLine() {
        let out = Numbers.apply(line)
        if out != line { print("- \(line)\n+ \(out)\n") }
    }
    exit(0)
case "review":
    // The daily read (PLAN-v1 B8): larynx review [--hours 24] [--text]. Counts only unless --text.
    let hours = Double(option("--hours") ?? "") ?? 24
    let showText = args.contains("--text")
    let since = Date().addingTimeInterval(-hours * 3600)
    let rows = History.shared.recent(limit: 5000).filter { $0.time >= since }.sorted { $0.time < $1.time }
    func pct(_ xs: [Int], _ q: Double) -> Int { let s = xs.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * q))] }
    print("Last \(Int(hours)) h: \(rows.count) dictations, \(Int(rows.reduce(0) { $0 + $1.audioSeconds })) s of speech")
    guard !rows.isEmpty else { exit(0) }
    let short = rows.filter { $0.audioSeconds < 60 }
    for engine in Set(short.map(\.engine)).sorted() {
        let ms = short.filter { $0.engine == engine }.map(\.totalMs)
        let ok = pct(ms, 0.5) <= 150 && pct(ms, 0.9) <= 350
        print("  speed \(engine): key-up to text p50 \(pct(ms, 0.5)) ms, p90 \(pct(ms, 0.9)) ms over \(ms.count)\(ok ? "" : "  OVER the 150/350 ms budget")")
    }
    let deliveries = Swift.Dictionary(grouping: rows, by: { $0.delivery }).map { "\($0.key) \($0.value.count)" }.sorted()
    print("  delivered: " + deliveries.joined(separator: ", "))
    var stageChanges: [String: Int] = [:]
    for r in rows { for st in r.steps where st.applied && st.before != st.after { stageChanges[st.stage, default: 0] += 1 } }
    print("  stages that changed text: " + stageChanges.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    let doubtful = rows.filter { $0.flags.contains("doubtful") }
    let undone = rows.filter { $0.flags.contains("undone") }
    let corrections = History.shared.corrections()
    let fixed = rows.filter { corrections[$0.id] != nil }
    var repeats: [(History.Row, History.Row)] = []
    for (a, b) in zip(rows, rows.dropFirst()) where a.app == b.app && b.time.timeIntervalSince(a.time) <= 90 && Golden.isWordFix(a.text, b.text) { repeats.append((a, b)) }
    var shadow: [String: Int] = [:]
    for r in rows { for st in r.steps where !st.applied && st.before != st.after { shadow[st.stage, default: 0] += 1 } }
    print("  not sure (doubtful): \(doubtful.count), undone (scratch that): \(undone.count), fixed by you: \(fixed.count), said again with a word changed: \(repeats.count)")
    print("  shadow proposals: " + (shadow.isEmpty ? "none" : shadow.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")))
    // From the log (no text there): microphone start, tails, edit watching, lessons. Since the log began.
    let logText = (try? String(contentsOfFile: NSHomeDirectory() + "/Library/Logs/Larynx.log", encoding: .utf8)) ?? ""
    let lines = logText.split(separator: "\n")
    let mics = lines.compactMap { l -> Int? in
        guard let r = l.range(of: #"mic (\d+) ms"#, options: .regularExpression) else { return nil }
        return Int(l[r].split(separator: " ")[1])
    }
    if !mics.isEmpty { print("  mic start (log): p50 \(pct(mics, 0.5)) ms, p90 \(pct(mics, 0.9)) ms over \(mics.count) presses (0 = warm)") }
    let count = { (needle: String) in lines.filter { $0.contains(needle) }.count }
    print("  log: tails \(count("kept listening")), edit watches \(count("edit watch:")) (readable \(count("edit watch: readable")), fixed \(count("word fixed"))), lessons \(count("learned from"))")
    if showText {
        for r in doubtful { print("\n[not sure] \(r.id)  \(r.text)") }
        for r in fixed { print("\n[fixed] \(r.id)\n   typed: \(r.text)\n   meant: \(corrections[r.id]?.text ?? "")") }
        for (a, b) in repeats { print("\n[said again] \(a.id)\n   first:  \(a.text)\n   second: \(b.text)") }
        for r in undone { print("\n[undone] \(r.id)  \(r.text)") }
    }
    exit(0)
case "capture-window":
    // Runs AppKit's event loop on the main thread itself (not inside a task, which would block the main actor).
    MainActor.assumeIsolated { CaptureWindow.shared.run(seconds: Double(option("--seconds") ?? "") ?? 60) }
case "golden":
    // Your own recordings with what you really said: the benchmark that matters most (bench/run.py --sets golden).
    //   larynx golden add <id> [--text "what was said"] [--source user|agent|edit|repeat]   (no --text: the typed text was right)
    //   larynx golden remove <id> | list | candidates [--apply]
    let sub = args.dropFirst().first ?? "list"
    let rows = History.shared.recent(limit: 5000)
    let clips = Golden.load()
    switch sub {
    case "add":
        guard args.count >= 3, let row = rows.first(where: { $0.id == args[2] }) else { print("larynx golden add <dictation id> [--text ...]"); exit(2) }
        do {
            let clip = try Golden.add(row, text: option("--text") ?? row.text, source: option("--source") ?? "user")
            print("added \(clip.id) (\(clip.source), \(String(format: "%.1f", clip.audioSeconds)) s); golden set: \(Golden.load().count) clips")
        } catch { print("\(error)"); exit(1) }
    case "remove":
        guard args.count >= 3 else { print("larynx golden remove <id>"); exit(2) }
        print((try? Golden.remove(id: args[2])) == true ? "removed \(args[2])" : "not in the golden set: \(args[2])")
    case "list":
        let seconds = clips.reduce(0) { $0 + $1.audioSeconds }
        let bySource = Swift.Dictionary(grouping: clips, by: { $0.source }).map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", ")
        print("\(clips.count) clips, \(Int(seconds)) s of audio\(clips.isEmpty ? "" : " (" + bySource + ")") in \(Golden.directory().path)")
        if args.contains("--text") { for c in clips { print("\(c.id)  [\(c.source)]  \(c.text)") } }
    case "candidates":
        // Dictations whose right text is known: you fixed a pasted word, or said it again with a word changed.
        let have = Set(clips.map(\.id))
        let withAudio = rows.filter { r in r.audioPath.map { FileManager.default.fileExists(atPath: $0) } ?? false && !have.contains(r.id) }
        var found: [(row: History.Row, text: String, source: String)] = []
        let corrections = History.shared.corrections()
        for r in withAudio { if let c = corrections[r.id] { found.append((r, c.text, c.source)) } }
        let ordered = rows.reversed() as [History.Row]
        for (a, b) in zip(ordered, ordered.dropFirst()) where a.app == b.app && b.time.timeIntervalSince(a.time) <= 90 {  // Relearn.window
            guard withAudio.contains(where: { $0.id == a.id }), !found.contains(where: { $0.row.id == a.id }), Golden.isWordFix(a.text, b.text) else { continue }
            found.append((a, b.text, "repeat"))
        }
        for f in found { print("\(f.row.id)  [\(f.source)]\n   typed:  \(f.row.text)\n   meant:  \(f.text)") }
        // The model was unsure of a word: worth a reference (larynx golden add <id> --text "..."), never added blind.
        let unsure = withAudio.filter { r in r.flags.contains("doubtful") && !found.contains { $0.row.id == r.id } }
        if !unsure.isEmpty { print("\nNot sure what was said (add with --text once you know):") }
        for r in unsure { print("\(r.id)  [doubtful]  \(r.text)") }
        if args.contains("--apply") {
            for f in found { _ = try? Golden.add(f.row, text: f.text, source: f.source) }
            print("added \(found.count); golden set: \(Golden.load().count) clips")
        } else {
            print("\(found.count) candidates\(found.isEmpty ? "" : "; --apply adds them")")
        }
    default:
        print("larynx golden add <id> [--text ...] | remove <id> | list [--text] | candidates [--apply]"); exit(2)
    }
    exit(0)
case "tidy":
    let mode = option("--mode").flatMap(CleanupMode.init(rawValue:)) ?? .standard
    let tidied = Tidy.apply(args.last ?? "", mode: mode)
    print(tidied)
    // --shadow: also what each shadow rule would make of it.
    if args.contains("--shadow") {
        for rule in Tidy.shadowRules { let p = rule.apply(tidied); if p != tidied { print("shadow:\(rule.name): \(p)") } }
    }
    exit(0)
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
        // --deliver: paste through the real delivery path, but only into the test capture window
        // (LARYNX_CAPTURE_PID), never into another app. The clipboard is put back afterwards whatever happens.
        var delivery = "none"
        var deliveredMs: Int?
        if args.contains("--deliver"), !result.text.isEmpty {
            guard let pid = Int32(ProcessInfo.processInfo.environment["LARYNX_CAPTURE_PID"] ?? ""),
                  let target = NSRunningApplication(processIdentifier: pid),
                  target.executableURL?.lastPathComponent == "larynx" else {
                emit(["event": "error", "message": "--deliver needs LARYNX_CAPTURE_PID of a running larynx capture-window"]); exit(2)
            }
            let board = NSPasteboard.general
            let saved: [[(NSPasteboard.PasteboardType, Data)]] = (board.pasteboardItems ?? []).map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            }
            let started = Date()
            delivery = await Inserter.deliver(result.text, to: target).label
            deliveredMs = ms(since: started)
            // A paste restores the clipboard itself after 0.5 s; the copy fallback leaves the words there. Either way,
            // if the test's words are still on the clipboard after that, put back what was there before.
            try? await Task.sleep(nanoseconds: 800_000_000)
            if board.string(forType: .string) == result.text {
                board.clearContents()
                board.writeObjects(saved.map { pairs -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in pairs { item.setData(data, forType: type) }
                    return item
                })
            }
        }
        if result.text.isEmpty { History.shared.discard(pending) }
        else { History.shared.complete(pending, transcript: result, delivery: delivery) }
        var body = try result.jsonObject()
        body["event"] = "result"
        body["id"] = pending.id
        body["delivery"] = delivery
        if let deliveredMs { body["deliverMs"] = deliveredMs }
        emit(body)
        exit(0)
    } catch {
        log("\(error)"); exit(1)
    }
}
