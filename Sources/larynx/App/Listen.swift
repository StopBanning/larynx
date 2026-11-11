import AppKit
import AVFoundation
import Foundation
import LarynxCore
import LarynxText

// Talk keys: --key, else `defaults write com.automatedworkflow.larynx keys fn,rightCommand`, else Fn, Right Option or Right Command.
let savedKeys = (Settings.shared.string(.keys)).split(separator: ",").compactMap { Hotkey.Key(rawValue: String($0)) }
let listenKeys: [Hotkey.Key] = option("--key").flatMap(Hotkey.Key.init(rawValue:)).map { [$0] }
    ?? (savedKeys.isEmpty ? [.fn, .rightOption, .rightCommand] : savedKeys)
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

func makeMenuBarItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Larynx")
    let menu = NSMenu()
    menu.delegate = MenuController.shared
    item.menu = menu
    statusItem = item
    statusLine = MenuController.shared.statusLine
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

@MainActor func runListen(keys: [Hotkey.Key]) async {
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
    _ = Loader.shared.vocabulary  // starts loading in the background

    // Each press is one utterance with its own target app, captured at key-down, so switching apps mid-sentence
    // (or a slow result) never sends text to the wrong place.
    // The menu bar app keeps the microphone open for `micWarm` seconds after a dictation, so the next press starts
    // instantly (a cold start loses the first 150-300 ms). Command-line tools and serve close it at once.
    if inApp { recorder.warmSeconds = { Double(Settings.shared.string(.micWarm)) ?? 30 } }
    let hotkey = Hotkey(keys: keys, onDown: {
        let session = ListenSession(target: NSWorkspace.shared.frontmostApplication)
        let micStart = Date()
        do { try recorder.start() } catch { session.reset(); log("\(error)"); return }
        let micMs = ms(since: micStart)
        ListenSession.current = session
        session.privateField = Privacy.isPrivate(app: session.target)
        NSSound(named: "Tink")?.play()
        setStatus("Listening...", recording: true)
        log("recording... [\(session.target?.bundleIdentifier ?? "?")] mic \(micMs) ms")
        guard inApp, Pill.enabled else { return }
        Pill.shared.listen(app: session.target, privateField: session.privateField,
                           field: Inserter.focusedFieldFrame(in: session.target), level: { recorder.level })
        session.previewTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak session] _ in
            Task { @MainActor in
                guard let session, session.isCurrentRecording, !ListenSession.previewBusy, recorder.isRecording else { return }
                let all = recorder.snapshot()
                guard Double(all.count) / Recorder.sampleRate >= 0.5 else { return }
                let window = Int(Recorder.sampleRate * 12)
                let trimmed = all.count > window
                let snap = trimmed ? Array(all.suffix(window)) : all
                ListenSession.previewBusy = true
                var words = (try? await transcriber.transcribe(snap)) ?? ""
                if trimmed, let cut = words.firstIndex(of: " ") { words = "…" + words[words.index(after: cut)...] }
                ListenSession.previewBusy = false
                if session.isCurrentRecording, recorder.isRecording, !words.isEmpty { Pill.shared.words(words) }
            }
        }
    }, onUp: {
        guard let session = ListenSession.current, session.state.finish() else { return }
        session.stopPreview()
        Task { @MainActor in
        let (samples, tailMs) = await recorder.stopAfterTail()
        if tailMs > 0 { log("kept listening \(tailMs) ms after the key: a word was still being said") }
        let app = session.target
        guard Double(samples.count) / Recorder.sampleRate >= 0.3 else {  // a tap, not dictation
            session.reset(); setStatus("Ready"); Pill.shared.hide(); return
        }
        NSSound(named: "Pop")?.play()
        setStatus("Transcribing...")
        Pill.shared.transcribing()
        let mode = CleanupMode.forApp(bundleID: app?.bundleIdentifier)
        // On disk before transcription starts, so a crash from here on can't lose the words.
        let pending = History.shared.begin(samples: samples, app: app?.bundleIdentifier, mode: mode, privateField: session.privateField)
        Task {
            defer { session.reset() }
            do {
                let result = try await finish(samples, clean: wantsClean, mode: mode)
                let text = result.text
                guard !text.isEmpty else {
                    History.shared.discard(pending)
                    if session.shouldPresent { Pill.shared.message("Didn't catch that", symbol: "ear", seconds: 1.2); setStatus("Heard nothing") }
                    log("heard nothing in \(result.audioSeconds) s of audio (mic muted, or Microphone permission missing?)")
                    return
                }
                guard session.state.deliver() else { return }
                // "Scratch that" on its own, soon after a dictation into the same app: undo that dictation instead.
                if Undo.isCommand(text), let last = Undo.last, last.matches(app) {
                    History.shared.discard(pending)
                    Undo.perform(last)
                    if session.shouldPresent { Pill.shared.message("Undid the last dictation", symbol: "arrow.uturn.backward", seconds: 1.5); setStatus("Ready") }
                    return
                }
                let delivery = await Inserter.deliver(text, to: app)
                let saved = History.shared.complete(pending, transcript: result, delivery: delivery.label)
                if delivery.isInserted { Undo.last = Undo.Entry(id: saved?.id, pid: app?.processIdentifier, time: Date()) }
                if let doubtful = result.doubtful { log("not sure about: \(doubtful.count) word\(doubtful.count == 1 ? "" : "s")") }
                MenuController.shared.remember(text)
                // Said it again with a word fixed? Learn the fix (never from password fields or snippets).
                let learned = session.privateField || result.snippet != nil ? { Relearn.reset(); return [] }()
                    : Relearn.check(text, app: app?.bundleIdentifier)
                // A repeat with a word fixed: the new words are what the previous dictation should have said.
                if !learned.isEmpty, let saved, let previous = History.shared.recent(limit: 2).first(where: { $0.id != saved.id }),
                   Golden.isWordFix(previous.text, text) {
                    History.shared.recordCorrection(id: previous.id, text: text, source: "repeat")
                }
                if case .copied(let why) = delivery {
                    // Nowhere to type: say so where the user is looking, and keep the words on the clipboard.
                    if session.shouldPresent { NSSound(named: "Funk")?.play(); setStatus("Copied, press ⌘V") }
                    log("copied: \(why)")
                    if session.shouldPresent {
                        Pill.shared.message("Copied: press ⌘V to paste", symbol: "doc.on.clipboard", tint: .systemOrange, seconds: 2.5)
                    }
                } else {
                    if session.shouldPresent {
                        Pill.shared.hide()
                        setStatus(delivery.isInserted ? "Ready" : "Ready (also on the clipboard)")
                    }
                    if delivery.isInserted { watchForFixes(text, in: app, id: saved?.id) }
                    if !learned.isEmpty {
                        log("learned from a repeat: " + Relearn.describe(learned))
                        Task { await reloadVocabulary() }
                        if session.shouldPresent { Pill.shared.message("Learned " + Relearn.describe(learned), symbol: "sparkles", seconds: 2.5) }
                    } else if let doubtful = result.doubtful, session.shouldPresent, !session.privateField,
                              Settings.shared.string(.doubtHint) != "off" {
                        // The model was unsure of a word: say which, so a glance catches it before sending.
                        Pill.shared.message("Not sure about " + doubtful.prefix(2).map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", "),
                                            symbol: "questionmark.circle", tint: .systemYellow, seconds: 2)
                    }
                }
                logTranscript("\(result.totalMs) ms [\(mode.rawValue) \(app?.bundleIdentifier ?? "?")] \(delivery.label), rewrite: \(logNote(result.rewrite)) (\(result.rewriteMs) ms), \(text.split(separator: " ").count) words, \(pending.persists ? pending.id : "not saved")", text: text)
            } catch {
                // The spool keeps the audio; the next launch transcribes it again.
                if session.shouldPresent { Pill.shared.hide(); setStatus("Error: \(error)") }
                log("\(error)\(pending.persists ? " (audio kept for recovery: \(pending.id))" : "")")
            }
        }
        }  // tail task
    }, onCancel: {
        if ListenSession.current?.locked == true { NSSound(named: "Bottle")?.play() }
        ListenSession.current?.reset()
        recorder.stop()
        Task { @MainActor in Pill.shared.hide() }
        setStatus("Ready")
        log("cancelled: another key was pressed (a shortcut, or Esc in hands-free)")
    }, onLock: {
        // Double-tap (or a toggle key): keep recording with no key held until the next press.
        guard let session = ListenSession.current, session.isCurrentRecording else { return }
        session.locked = true
        Pill.shared.lock()
        setStatus("Hands-free: press the key to finish, Esc to cancel", recording: true)
        log("hands-free")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)  // a forgotten recording stops after 30 minutes
            if ListenSession.current === session, session.state.phase == .recording { activeHotkey?.finishLocked() }
        }
    })
    hotkey.doubleTapLocks = Settings.shared.string(.handsFree) != "off"
    hotkey.toggleKeys = Settings.shared.string(.toggleKeys).split(separator: ",")
        .compactMap { Hotkey.Key(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
    let started = await MainActor.run { hotkey.start() }
    guard started else { setStatus("macOS refused the key listener"); log("macOS refused the key listener"); return }
    activeHotkey = hotkey
    setStatus(Inserter.isTrusted ? "Ready" : "Ready (needs Accessibility to paste)")
    var ready = "ready: hold " + keys.map(\.label).joined(separator: " or ") + ", speak, release"
    if hotkey.doubleTapLocks { ready += "; double-tap for hands-free" }
    let toggles: [String] = hotkey.toggleKeys.map(\.label)
    if !toggles.isEmpty { ready += "; " + toggles.joined(separator: " or ") + " toggles hands-free" }
    log(ready)
    let recovered = await recoverAbandoned(before: launchedAt)
    if !recovered.isEmpty {
        if ListenSession.current == nil {
            Pill.shared.message("Recovered \(recovered.count == 1 ? "a dictation" : "\(recovered.count) dictations") from before a crash: see Recent",
                                symbol: "arrow.counterclockwise", seconds: 4)
        }
    }
    History.shared.prune()
}

let launchedAt = Date()

/// Transcribes recordings a crash left in the spool and saves each as a recovered dictation.
/// A recording that fails again stays in the spool for the next launch.
func recoverAbandoned(before cutoff: Date) async -> [History.Row] {
    var rows: [History.Row] = []
    for (pending, samples) in History.shared.abandoned(olderThan: cutoff) {
        do {
            let result = try await finish(samples, clean: false, mode: pending.mode)
            guard !result.text.isEmpty else { History.shared.discard(pending); continue }
            if let row = History.shared.complete(pending, transcript: result, delivery: "recovered", flags: ["recovered"]) {
                rows.append(row)
                logTranscript("recovered dictation \(row.id) (\(row.text.split(separator: " ").count) words)", text: row.text)
            }
        } catch {
            log("could not recover \(pending.id): \(error)")
        }
    }
    return rows
}

/// Transcript text stays out of the log unless `debugText` is on.
func logTranscript(_ line: String, text: String) {
    log(Settings.shared.string(.debugText) == "on" ? "\(line): \(text)" : line)
}

/// Rewrite notes can quote the rejected model output; keep only the decision.
func logNote(_ note: String) -> String {
    if let r = note.range(of: ": rejected") { return String(note[..<r.upperBound]) }
    return note
}

/// Watches the text field for 20 seconds after a paste and learns any word the user corrected.
/// `defaults write com.automatedworkflow.larynx learn off` turns it off.
func watchForFixes(_ pasted: String, in app: NSRunningApplication?, id: String? = nil) {
    guard Settings.shared.string(.learn) != "off" else { return }
    Task { @MainActor in
        // "edit watch:" lines count outcomes without any text (PLAN-v1 B7: prove learning from edits fires).
        guard let field = Learner.focusedTextElement(in: app) else { log("edit watch: field not readable"); return }
        // Look every second for 20 s and keep the last version that still holds the pasted words: people fix a word
        // and hit send within seconds, and after sending the field is empty.
        var latest: String?
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let now = Learner.text(of: field) else { break }
            if Learner.stillHolds(pasted, in: now) { latest = now } else if latest != nil { break }
        }
        guard let now = latest else { log("edit watch: readable, dictation not found in it"); return }
        let fixes = Learner.fixes(pasted: pasted, now: now)
        guard !fixes.isEmpty else { log("edit watch: readable, no word fixed"); return }
        log("edit watch: readable, \(fixes.count) word\(fixes.count == 1 ? "" : "s") fixed")
        // What the dictation should have said, for the golden set.
        if let id { History.shared.recordCorrection(id: id, text: Learner.applying(fixes, to: pasted), source: "edit") }
        let added = Learner.learn(fixes)
        log("learned from your fix: " + fixes.map { "\($0.heard) -> \($0.fixed)" }.joined(separator: ", "))
        guard !added.isEmpty else { return }
        Task { await reloadVocabulary() }
        if ListenSession.current == nil { Pill.shared.message("Learned: " + added.joined(separator: ", "), symbol: "sparkles", seconds: 2) }
    }
}



/// "Scratch that": undo the last dictation (⌘Z once in the app it went to) when it is said on its own within 30 s,
/// into the same app. Otherwise the words are typed like any others. Also the menu's Undo Last Dictation.
enum Undo {
    struct Entry {
        let id: String?
        let pid: pid_t?
        let time: Date
        func matches(_ app: NSRunningApplication?) -> Bool {
            Date().timeIntervalSince(time) <= Undo.window && pid != nil && app?.processIdentifier == pid
        }
    }
    static let window: TimeInterval = 30
    nonisolated(unsafe) static var last: Entry?

    static func isCommand(_ text: String) -> Bool { VoiceCommand.isUndo(text) }

    static func perform(_ entry: Entry) {
        Inserter.sendUndo()
        if let id = entry.id { History.shared.addFlag("undone", to: id) }
        last = nil
        log("undid the last dictation (scratch that)")
    }
}
