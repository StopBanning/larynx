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
let wantsClean = args.contains("--clean")

let usage = """
    larynx: local, offline dictation for macOS (Parakeet TDT v3 on the Neural Engine)

    larynx transcribe <audio file> [--clean]   print the transcript of a file
    larynx listen [--key fn|rightOption|rightCommand|rightControl] [--clean]
                                              hold the key, speak, release: text pastes where your cursor is
    larynx serve                               JSON lines on stdin/stdout, for apps such as Locust (see docs/INTEGRATION.md)

    --models-dir <path>   where the speech model lives (downloaded once, about 500 MB)
    --engine parakeet|clean   clean = English-only model that drops ums, false starts and repeats
    --clean               tidy the text with Apple's on-device model when available
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
    ?? Engine(rawValue: UserDefaults.standard.string(forKey: "engine") ?? "") ?? .parakeet
let loadTask = Task { try await transcriber.load(modelsDir: modelsDir, engine: engine) }

func requestMicrophone() async -> Bool {
    if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return true }
    return await AVCaptureDevice.requestAccess(for: .audio)
}

/// Transcribes, optionally cleans, and reports timing for one utterance.
func finish(_ samples: [Float], clean: Bool) async throws -> [String: Any] {
    let started = Date()
    try await loadTask.value
    let raw = try await transcriber.transcribe(samples)
    let asrMs = ms(since: started)
    let text = clean ? await Cleaner.clean(raw) : raw
    return [
        "text": text, "raw": raw,
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
        try await loadTask.value
        log("model ready in \(ms(since: loadStart)) ms")
        let result = try await finish(samples, clean: wantsClean)
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
    do { try await loadTask.value } catch { setStatus("Model failed to load"); log("\(error)"); return }

    let hotkey = Hotkey(keys: keys, onDown: {
        do { try recorder.start(); NSSound(named: "Tink")?.play(); setStatus("Listening...", recording: true); log("recording...") }
        catch { log("\(error)") }
    }, onUp: {
        let samples = recorder.stop()
        guard Double(samples.count) / Recorder.sampleRate >= 0.3 else { setStatus("Ready"); return }  // a tap, not dictation
        NSSound(named: "Pop")?.play()
        setStatus("Transcribing...")
        Task {
            do {
                let result = try await finish(samples, clean: wantsClean)
                let text = result["text"] as! String
                guard !text.isEmpty else {
                    setStatus("Heard nothing")
                    log("heard nothing in \(result["audioSeconds"]!) s of audio (mic muted, or Microphone permission missing?)")
                    return
                }
                await MainActor.run {
                    do { try Inserter.paste(text); setStatus("Ready") }
                    catch { setStatus("Could not paste: \(error)"); log("\(error)") }
                }
                log("\(result["totalMs"]!) ms: \(text)")
            } catch { setStatus("Error: \(error)"); log("\(error)") }
        }
    }, onCancel: {
        recorder.stop()
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
            try await loadTask.value
            emit(["event": "ready", "model": engine.modelName, "cleanup": Cleaner.isAvailable,
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
                var result = try await finish(samples, clean: request["clean"] as? Bool ?? false)
                if request["paste"] as? Bool == true, let text = result["text"] as? String {
                    do { try await MainActor.run { try Inserter.paste(text) }; result["pasted"] = true }
                    catch { result["pasted"] = false; result["pasteError"] = "\(error)" }
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
                var result = try await finish(try loadAudioFile(URL(fileURLWithPath: path)), clean: request["clean"] as? Bool ?? false)
                result["event"] = "result"
                reply(result)
            } catch { reply(["event": "error", "message": "\(error)"]) }
        case "status":
            reply(["event": "status", "loaded": await transcriber.isLoaded, "recording": recorder.isRecording,
                   "cleanup": Cleaner.isAvailable, "pasteAllowed": Inserter.isTrusted])
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
    makeMenuBarItem(keys: listenKeys)
    Task { await runListen(keys: listenKeys) }
    app.run()
}
switch args.first {
case "transcribe": Task { await runTranscribe() }
case "listen": Task { await runListen(keys: listenKeys) }
case "serve": Task { await runServe() }
default: print(usage); exit(args.isEmpty || args.first == "--help" || args.first == "-h" ? 0 : 2)
}
RunLoop.main.run()
