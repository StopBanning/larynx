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
case "listen": Task { await runListen(keys: listenKeys) }
case "serve": Task { await runServe() }
case "mcp": Task { await runMCP() }
case "focus":
    // What has focus in the front app, after an optional delay: larynx focus [seconds]. Needs Accessibility.
    let wait = Double(args.dropFirst().first ?? "") ?? 0
    Thread.sleep(forTimeInterval: wait)
    let app = NSWorkspace.shared.frontmostApplication
    let f = Inserter.focusedField(in: app)
    print("\(app?.bundleIdentifier ?? "?"): editable=\(f.editable.map(String.init) ?? "unknown") role=\(f.role)")
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
    // Holds the live preview on screen so it can be looked at or screenshotted: larynx pill-demo [seconds] [text]
    let seconds = Double(args.dropFirst().first ?? "") ?? 15
    let sample = args.count > 2 ? args[2] : "I wanna add you on my schedule for Wednesday, and can you send the report before the meeting starts on Friday afternoon?"
    NSApplication.shared.setActivationPolicy(.accessory)
    Task { @MainActor in
        Pill.shared.show(sample)
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
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
