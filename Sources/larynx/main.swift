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
let autoRewrite = (option("--rewrite") ?? UserDefaults.standard.string(forKey: "rewrite") ?? "auto") == "auto"
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

// MARK: - Engine

let transcriber = Transcriber()
let recorder = Recorder()
nonisolated(unsafe) var activeHotkey: Hotkey?
let engine: Engine = option("--engine").flatMap(Engine.init(rawValue:))
    ?? Engine(rawValue: UserDefaults.standard.string(forKey: "engine") ?? "") ?? .clean
/// Loads the speech model on first use only, so text-only commands never touch it.
final class Loader: @unchecked Sendable {
    static let shared = Loader()
    lazy var task: Task<Void, Error> = Task { try await transcriber.load(modelsDir: modelsDir, engine: engine) }
}

/// The other speech model, used only when the main one hears nothing in a clip that clearly has speech in it.
let fallbackTranscriber = Transcriber()
final class FallbackLoader: @unchecked Sendable {
    static let shared = FallbackLoader()
    lazy var task: Task<Void, Error> = Task { try await fallbackTranscriber.load(modelsDir: modelsDir, engine: engine.other) }
}

/// Retries an empty transcript with the other model when the clip is long and loud enough to be speech
/// and that model is already downloaded. `LARYNX_FORCE_FALLBACK=1` treats every first pass as empty, for testing.
func transcribeWithFallback(_ samples: [Float]) async throws -> (text: String, engine: String) {
    let forced = ProcessInfo.processInfo.environment["LARYNX_FORCE_FALLBACK"] == "1"
    let first = forced ? "" : try await transcriber.transcribe(samples)
    guard first.isEmpty else { return (first, engine.rawValue) }
    let seconds = Double(samples.count) / Recorder.sampleRate, level = Recorder.rms(samples)
    guard seconds >= 0.5, level >= 0.01 || forced, engine.other.isDownloaded(in: modelsDir) else { return (first, engine.rawValue) }
    try await FallbackLoader.shared.task.value
    let second = try await fallbackTranscriber.transcribe(samples)
    log("fallback engine: \(engine.other.rawValue) (\(String(format: "%.1f", seconds)) s, rms \(String(format: "%.3f", level))): \(second.isEmpty ? "also empty" : second)")
    return (second, engine.other.rawValue)
}

func requestMicrophone() async -> Bool {
    if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return true }
    return await AVCaptureDevice.requestAccess(for: .audio)
}

/// Transcribes, optionally cleans, and reports timing for one utterance.
func finish(_ samples: [Float], clean: Bool, mode: CleanupMode = .standard, tidy: Bool = !verbatim) async throws -> [String: Any] {
    let started = Date()
    try await Loader.shared.task.value
    let (raw, usedEngine) = try await transcribeWithFallback(samples)
    let asrMs = ms(since: started)
    let tidied = tidy ? Tidy.apply(Dictionary.apply(raw), mode: mode) : raw
    let rewriteStart = Date()
    let outcome = (clean || autoRewrite) ? await Cleaner.rewrite(tidied, mode: mode, force: clean)
                                         : Cleaner.Outcome(text: tidied, used: false, note: "off")
    let text = outcome.text
    return [
        "text": text, "raw": raw, "mode": mode.rawValue, "engine": usedEngine,
        "rewrite": outcome.note, "rewritten": outcome.used, "rewriteMs": outcome.note == "off" ? 0 : ms(since: rewriteStart),
        "audioSeconds": (Double(samples.count) / Recorder.sampleRate * 100).rounded() / 100,
        "asrMs": asrMs, "totalMs": ms(since: started),
    ]
}

// MARK: - Modes

func runTranscribe() async {
    guard args.count >= 2 else { print(usage); exit(2) }
    do {
        let samples = try loadAudioFile(URL(fileURLWithPath: args[1]))
        let loadStart = Date()
        try await Loader.shared.task.value
        log("model ready in \(ms(since: loadStart)) ms")
        let result = try await finish(samples, clean: wantsClean, mode: option("--mode").flatMap(CleanupMode.init(rawValue:)) ?? .standard)
        log("\(result["audioSeconds"]!) s of audio, speech \(result["asrMs"]!) ms, total \(result["totalMs"]!) ms")
        print(result["text"] as! String)
        exit(0)
    } catch {
        log("\(error)"); exit(1)
    }
}

// MARK: - Menu bar (app mode)

let inApp = Bundle.main.bundleURL.pathExtension == "app"
nonisolated(unsafe) var statusItem: NSStatusItem?
nonisolated(unsafe) var statusLine: NSMenuItem?

func setStatus(_ text: String, recording: Bool = false) {
    DispatchQueue.main.async {
        statusLine?.title = text
        statusItem?.button?.image = NSImage(systemSymbolName: recording ? "mic.fill" : "mic", accessibilityDescription: "Larynx")
    }
}

func makeMenuBarItem(keys: [Hotkey.Key]) {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Larynx")
    let menu = NSMenu()
    let line = NSMenuItem(title: "Starting...", action: nil, keyEquivalent: "")
    line.isEnabled = false
    menu.addItem(line)
    let hint = NSMenuItem(title: "Hold " + keys.map(\.label).joined(separator: " or ") + " to talk", action: nil, keyEquivalent: "")
    hint.isEnabled = false
    menu.addItem(hint)
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Quit Larynx", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    item.menu = menu
    statusItem = item
    statusLine = line
}

extension Hotkey.Key {
    var label: String {
        switch self {
        case .fn: return "Fn"
        case .rightOption: return "Right Option"
        case .rightCommand: return "Right Command"
        case .rightControl: return "Right Control"
        }
    }
}

func runListen(keys: [Hotkey.Key]) async {
    setStatus("Asking for permissions...")
    guard await requestMicrophone() else { setStatus("Microphone access refused"); log("microphone access was refused"); return }
    if !Hotkey.canListen {
        Hotkey.requestListen()
        log("waiting for Input Monitoring: System Settings > Privacy & Security > Input Monitoring")
    }
    if !Inserter.isTrusted {
        Inserter.requestTrust()
        log("waiting for Accessibility: System Settings > Privacy & Security > Accessibility")
    }
    while !Hotkey.canListen {
        setStatus("Needs Input Monitoring permission")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
    setStatus("Loading speech model...")
    do { try await Loader.shared.task.value } catch { setStatus("Model failed to load"); log("\(error)"); return }

    // Each press is one utterance with its own target app, captured at key-down, so switching apps mid-sentence
    // (or a slow result) never sends text to the wrong place.
    var target: NSRunningApplication?
    var previewTimer: Timer?
    var previewBusy = false
    var session = 0
    func stopPreview() { previewTimer?.invalidate(); previewTimer = nil }

    let hotkey = Hotkey(keys: keys, onDown: {
        session += 1
        target = NSWorkspace.shared.frontmostApplication
        do { try recorder.start() } catch { log("\(error)"); return }
        NSSound(named: "Tink")?.play()
        setStatus("Listening...", recording: true)
        log("recording... [\(target?.bundleIdentifier ?? "?")]")
        guard inApp, Pill.enabled else { return }
        Task { @MainActor in Pill.shared.show("Listening…") }
        let mine = session
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in
            guard !previewBusy, recorder.isRecording, session == mine else { return }
            let snap = recorder.snapshot()
            guard Double(snap.count) / Recorder.sampleRate >= 0.5 else { return }
            previewBusy = true
            Task {
                let words = (try? await transcriber.transcribe(snap)) ?? ""
                await MainActor.run {
                    previewBusy = false
                    if session == mine, recorder.isRecording, !words.isEmpty { Pill.shared.show(words) }
                }
            }
        }
    }, onUp: {
        stopPreview()
        let samples = recorder.stop()
        let app = target
        guard Double(samples.count) / Recorder.sampleRate >= 0.3 else {  // a tap, not dictation
            setStatus("Ready"); Task { @MainActor in Pill.shared.hide() }; return
        }
        NSSound(named: "Pop")?.play()
        setStatus("Transcribing...")
        Task { @MainActor in Pill.shared.show("Transcribing…") }
        let mode = CleanupMode.forApp(bundleID: app?.bundleIdentifier)
        Task {
            do {
                let result = try await finish(samples, clean: wantsClean, mode: mode)
                let text = result["text"] as! String
                guard !text.isEmpty else {
                    await MainActor.run { Pill.shared.hide() }
                    setStatus("Heard nothing")
                    log("heard nothing in \(result["audioSeconds"]!) s of audio (mic muted, or Microphone permission missing?)")
                    return
                }
                let delivery = await Inserter.deliver(text, to: app)
                await MainActor.run { Pill.shared.hide() }
                if case .copied(let why) = delivery {
                    NSSound(named: "Funk")?.play()
                    setStatus("Copied, press ⌘V")
                    log("copied: \(why)")
                } else {
                    setStatus("Ready")
                }
                log("\(result["totalMs"]!) ms [\(mode.rawValue) \(app?.bundleIdentifier ?? "?")] \(delivery.label), rewrite: \(result["rewrite"] ?? "-") (\(result["rewriteMs"] ?? 0) ms): \(text)")
            } catch {
                await MainActor.run { Pill.shared.hide() }
                setStatus("Error: \(error)"); log("\(error)")
            }
        }
    }, onCancel: {
        stopPreview()
        recorder.stop()
        Task { @MainActor in Pill.shared.hide() }
        setStatus("Ready")
        log("cancelled: another key was pressed (a shortcut)")
    })
    let started = await MainActor.run { hotkey.start() }
    guard started else { setStatus("macOS refused the key listener"); log("macOS refused the key listener"); return }
    activeHotkey = hotkey
    setStatus(Inserter.isTrusted ? "Ready" : "Ready (needs Accessibility to paste)")
    log("ready: hold " + keys.map(\.label).joined(separator: " or ") + ", speak, release")
}

/// One JSON object per line in, one per line out. Commands run in order.
func runServe() async {
    let lines = AsyncStream<String> { continuation in
        Thread {
            while let line = readLine() { continuation.yield(line) }
            continuation.finish()
        }.start()
    }
    Task {
        do {
            try await Loader.shared.task.value
            emit(["event": "ready", "model": engine.modelName, "rewriteAvailable": Cleaner.isAvailable,
                  "pasteAllowed": Inserter.isTrusted])
        } catch {
            emit(["event": "error", "message": "model failed to load: \(error)"])
        }
    }
    for await line in lines {
        guard let data = line.data(using: .utf8),
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cmd = request["cmd"] as? String
        else { emit(["event": "error", "message": "expected a JSON object with a cmd"]); continue }
        let id = request["id"]
        func reply(_ body: [String: Any]) {
            var body = body
            if let id { body["id"] = id }
            emit(body)
        }
        switch cmd {
        case "start":
            guard await requestMicrophone() else { reply(["event": "error", "message": "microphone access was refused"]); continue }
            do { try recorder.start(); reply(["event": "recording"]) }
            catch { reply(["event": "error", "message": "\(error)"]) }
        case "stop":
            let samples = recorder.stop()
            reply(["event": "processing", "audioSeconds": Double(samples.count) / Recorder.sampleRate])
            do {
                var result = try await finish(samples, clean: request["clean"] as? Bool ?? false,
                                              mode: (request["mode"] as? String).flatMap(CleanupMode.init(rawValue:)) ?? .standard,
                                              tidy: !(request["verbatim"] as? Bool ?? false))
                if request["paste"] as? Bool == true, let text = result["text"] as? String, !text.isEmpty {
                    let delivery = await Inserter.deliver(text)
                    result["delivered"] = delivery.label
                    result["pasted"] = delivery == .inserted
                    if case .copied(let why) = delivery { result["pasteError"] = why }
                }
                result["event"] = "result"
                reply(result)
            } catch { reply(["event": "error", "message": "\(error)"]) }
        case "cancel":
            recorder.stop()
            reply(["event": "cancelled"])
        case "transcribe":
            guard let path = request["path"] as? String else { reply(["event": "error", "message": "transcribe needs a path"]); continue }
            do {
                var result = try await finish(try loadAudioFile(URL(fileURLWithPath: path)), clean: request["clean"] as? Bool ?? false,
                                              mode: (request["mode"] as? String).flatMap(CleanupMode.init(rawValue:)) ?? .standard,
                                              tidy: !(request["verbatim"] as? Bool ?? false))
                result["event"] = "result"
                reply(result)
            } catch { reply(["event": "error", "message": "\(error)"]) }
        case "status":
            reply(["event": "status", "loaded": await transcriber.isLoaded, "recording": recorder.isRecording,
                   "rewriteAvailable": Cleaner.isAvailable, "pasteAllowed": Inserter.isTrusted])
        case "quit":
            recorder.stop()
            exit(0)
        default:
            reply(["event": "error", "message": "unknown cmd \(cmd)"])
        }
    }
    exit(0)
}

// MARK: - Entry

setvbuf(stdout, nil, _IOLBF, 0)
// Talk keys: --key, else `defaults write com.automatedworkflow.larynx keys fn,rightCommand`, else Fn, Right Option or Right Command.
let savedKeys = (UserDefaults.standard.string(forKey: "keys") ?? "").split(separator: ",").compactMap { Hotkey.Key(rawValue: String($0)) }
let listenKeys: [Hotkey.Key] = option("--key").flatMap(Hotkey.Key.init(rawValue:)).map { [$0] }
    ?? (savedKeys.isEmpty ? [.fn, .rightOption, .rightCommand] : savedKeys)
if inApp && args.isEmpty {
    // Launched as Larynx.app: log to ~/Library/Logs/Larynx.log and live in the menu bar.
    let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Larynx.log")
    freopen(logURL.path, "a", stderr)
    setvbuf(stderr, nil, _IOLBF, 0)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Dictionary.ensureExists()
    makeMenuBarItem(keys: listenKeys)
    Task { await runListen(keys: listenKeys) }
    app.run()
}
switch args.first {
case "transcribe": Task { await runTranscribe() }
case "listen": Task { await runListen(keys: listenKeys) }
case "serve": Task { await runServe() }
case "mcp": Task { await runMCP() }
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
RunLoop.main.run()
