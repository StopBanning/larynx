import AppKit
import AVFoundation
import Foundation
import LarynxCore

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
    let hotkey = Hotkey(keys: keys, onDown: {
        let session = ListenSession(target: NSWorkspace.shared.frontmostApplication)
        do { try recorder.start() } catch { session.reset(); log("\(error)"); return }
        ListenSession.current = session
        NSSound(named: "Tink")?.play()
        setStatus("Listening...", recording: true)
        log("recording... [\(session.target?.bundleIdentifier ?? "?")]")
        guard inApp, Pill.enabled else { return }
        Pill.shared.show("Listening…")
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
                if session.isCurrentRecording, recorder.isRecording, !words.isEmpty { Pill.shared.show(words) }
            }
        }
    }, onUp: {
        guard let session = ListenSession.current, session.state.finish() else { return }
        session.stopPreview()
        let samples = recorder.stop()
        let app = session.target
        guard Double(samples.count) / Recorder.sampleRate >= 0.3 else {  // a tap, not dictation
            session.reset(); setStatus("Ready"); Pill.shared.hide(); return
        }
        NSSound(named: "Pop")?.play()
        setStatus("Transcribing...")
        Task { @MainActor in Pill.shared.show("Transcribing…") }
        let mode = CleanupMode.forApp(bundleID: app?.bundleIdentifier)
        Task {
            defer { session.reset() }
            do {
                let result = try await finish(samples, clean: wantsClean, mode: mode)
                let text = result.text
                guard !text.isEmpty else {
                    if session.shouldPresent { Pill.shared.hide(); setStatus("Heard nothing") }
                    log("heard nothing in \(result.audioSeconds) s of audio (mic muted, or Microphone permission missing?)")
                    return
                }
                guard session.state.deliver() else { return }
                let delivery = await Inserter.deliver(text, to: app)
                MenuController.shared.remember(text)
                if case .copied(let why) = delivery {
                    // Nowhere to type: say so where the user is looking, and keep the words on the clipboard.
                    if session.shouldPresent { NSSound(named: "Funk")?.play(); setStatus("Copied, press ⌘V") }
                    log("copied: \(why)")
                    if session.shouldPresent { Pill.shared.show(Pill.enabled ? "Copied, press ⌘V to paste" : "") }
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if session.shouldPresent { Pill.shared.hide() }
                } else {
                    if session.shouldPresent {
                        Pill.shared.hide()
                        setStatus(delivery == .inserted ? "Ready" : "Ready (also on the clipboard)")
                    }
                    if delivery == .inserted { watchForFixes(text, in: app) }
                }
                log("\(result.totalMs) ms [\(mode.rawValue) \(app?.bundleIdentifier ?? "?")] \(delivery.label), rewrite: \(result.rewrite) (\(result.rewriteMs) ms): \(text)")
            } catch {
                if session.shouldPresent { Pill.shared.hide(); setStatus("Error: \(error)") }
                log("\(error)")
            }
        }
    }, onCancel: {
        ListenSession.current?.reset()
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

/// Reads the text field again 15 seconds after a paste and learns any word the user corrected.
/// `defaults write com.automatedworkflow.larynx learn off` turns it off.
func watchForFixes(_ pasted: String, in app: NSRunningApplication?) {
    guard Settings.shared.string(.learn) != "off" else { return }
    Task { @MainActor in
        guard let field = Learner.focusedTextElement(in: app) else { return }
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        guard let now = Learner.text(of: field) else { return }
        let fixes = Learner.fixes(pasted: pasted, now: now)
        guard !fixes.isEmpty else { return }
        let added = Learner.learn(fixes)
        log("learned from your fix: " + fixes.map { "\($0.heard) -> \($0.fixed)" }.joined(separator: ", "))
        guard !added.isEmpty else { return }
        Pill.shared.show("Learned: " + added.joined(separator: ", "))
        Task { await reloadVocabulary() }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if !recorder.isRecording { Pill.shared.hide() }
    }
}

