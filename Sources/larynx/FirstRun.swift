import AppKit
import AVFoundation
import LarynxCore
import SwiftUI

/// First run (PLAN-v1 D2): the three permissions with live status, a microphone level test, the speech model's
/// state, the talk key, and a box to try a dictation. Larynx never flips a permission itself: each button opens the
/// right pane of System Settings. Shown at launch only on a fresh install or when something is missing; the menu's
/// Setup… opens it any time.
@MainActor
final class FirstRun {
    static let shared = FirstRun()
    private var window: NSWindow?

    /// At launch: open the window if setup isn't finished; otherwise remember it is, so it never pops up again.
    func showIfNeeded() {
        let model = FirstRunModel.shared
        model.refresh()
        if model.allReady {
            if LarynxCore.Settings.shared.string(.onboarded) != "true" { try? LarynxCore.Settings.shared.set("true", for: .onboarded) }
            return
        }
        show()
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 760),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Set up Larynx"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: FirstRunView())
            w.center()
            window = w
        }
        FirstRunModel.shared.start()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { FirstRunModel.shared.stop(); window?.close() }
}

@MainActor
final class FirstRunModel: ObservableObject {
    static let shared = FirstRunModel()
    @Published var microphone = false
    @Published var accessibility = false
    @Published var inputMonitoring = false
    @Published var modelReady = false
    /// Downloading with a fraction, preparing, or ready: every wait gets a bar and a time (PLAN-launch L0.7).
    @Published var modelState: ModelSetup.State = .preparing
    @Published var preparingSeconds = 0
    private var samples: [(time: Date, bytes: Int64)] = []
    private var preparingSince: Date?
    @Published var level: Float = 0
    @Published var tryText = ""
    private var timer: Timer?
    private var meter: AVAudioEngine?

    var allReady: Bool { microphone && accessibility && inputMonitoring && modelReady }

    func refresh() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibility = Inserter.isTrusted
        inputMonitoring = Hotkey.canListen
        modelReady = engine.isDownloaded(in: modelsDir)
    }

    /// The model folder's size against its final size, and the speed over the last ten seconds.
    func refreshModel() {
        let bytes = modelsDir.map { ModelSetup.folderBytes($0.appendingPathComponent(engine.folder, isDirectory: true)) } ?? 0
        let now = Date()
        samples.append((now, bytes))
        samples.removeAll { now.timeIntervalSince($0.time) > 10 }
        let rate = samples.first.flatMap { first -> Double? in
            let seconds = now.timeIntervalSince(first.time)
            return seconds >= 2 ? Double(bytes - first.bytes) / seconds : nil
        }
        Task { @MainActor in
            let loaded = await transcriber.isLoaded
            let state = ModelSetup.state(loaded: loaded, bytes: bytes, expected: ModelSetup.expectedBytes(engine), bytesPerSecond: rate)
            if state == .preparing {
                if self.preparingSince == nil { self.preparingSince = now }
                self.preparingSeconds = Int(now.timeIntervalSince(self.preparingSince ?? now))
            } else { self.preparingSince = nil }
            self.modelState = state
        }
    }

    /// Live status every second while the window is open, and the level meter once the microphone is allowed.
    func start() {
        refresh()
        refreshModel()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                FirstRunModel.shared.refresh()
                FirstRunModel.shared.refreshModel()
                if FirstRunModel.shared.microphone { FirstRunModel.shared.startMeter() }
            }
        }
        if microphone { startMeter() }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        meter?.inputNode.removeTap(onBus: 0); meter?.stop(); meter = nil
        level = 0
    }

    /// A separate audio engine for the meter only: nothing is recorded or kept.
    func startMeter() {
        guard meter == nil, !recorder.isRecording else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
            let rms = (sum / Float(max(1, buffer.frameLength))).squareRoot()
            DispatchQueue.main.async { MainActor.assumeIsolated { FirstRunModel.shared.level = min(1, rms * 8) } }
        }
        do { try engine.start(); meter = engine } catch { input.removeTap(onBus: 0) }
    }

    static func openPane(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}

private struct StepRow: View {
    let done: Bool
    let title: String
    let detail: String
    let button: String
    let action: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary).font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !done, !button.isEmpty { Button(button, action: action) }
        }
    }
}

/// The speech model's wait, in plain words: a bar with megabytes and time left while it downloads, a moving bar with
/// the time so far while macOS prepares it, a tick when it is ready.
struct ModelRow: View {
    let state: ModelSetup.State
    let preparingSeconds: Int
    var body: some View {
        switch state {
        case .ready:
            StepRow(done: true, title: "Ready", detail: "Runs on this Mac's Neural Engine. Nothing is sent anywhere.", button: "") {}
        case .downloading(let fraction, let megabytes, let total, let secondsLeft):
            VStack(alignment: .leading, spacing: 6) {
                Text("Downloading the speech model").font(.headline)
                ProgressView(value: min(0.99, fraction))
                Text("\(megabytes) of \(total) MB" + (secondsLeft.map { ", " + ModelSetup.timeLeft($0) + " left" } ?? "") + ". This happens once.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .preparing:
            VStack(alignment: .leading, spacing: 6) {
                Text("Getting the speech model ready for this Mac").font(.headline)
                ProgressView().progressViewStyle(.linear)
                Text("This happens once and usually takes 1 to 3 minutes" + (preparingSeconds >= 5 ? " (\(preparingSeconds / 60):\(String(format: "%02d", preparingSeconds % 60)) so far)" : "")
                     + ". After that it loads in about a second.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct FirstRunView: View {
    @ObservedObject private var model = FirstRunModel.shared
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Think out loud. Larynx writes it down.").font(.title3.bold())
                    Text("Three permissions, then hold a key and speak. Nothing leaves your Mac.").foregroundStyle(.secondary)
                }
            }
            Section("Permissions") {
                StepRow(done: model.microphone, title: "Microphone",
                        detail: "To hear you while you hold the talk key. Your voice is turned into text on this Mac and is never sent anywhere.",
                        button: "Allow") {
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else { FirstRunModel.openPane("Privacy_Microphone") }
                }
                StepRow(done: model.inputMonitoring, title: "Input Monitoring",
                        detail: "To notice your talk key in any app. Larynx only looks for that key; it never records what you type.",
                        button: "Open Settings") { Hotkey.requestListen(); FirstRunModel.openPane("Privacy_ListenEvent") }
                StepRow(done: model.accessibility, title: "Accessibility",
                        detail: "To put your words where the cursor is and check they arrived. Password fields are never read or saved.",
                        button: "Open Settings") { Inserter.requestTrust(); FirstRunModel.openPane("Privacy_Accessibility") }
            }
            Section {
                Button("What Larynx can and can't see") { NSWorkspace.shared.open(URL(string: Links.repo + "/blob/main/docs/PRIVACY.md")!) }
                    .buttonStyle(.link).font(.caption)
            }
            Section("Microphone test") {
                HStack {
                    Image(systemName: "mic.fill").foregroundStyle(.secondary)
                    ProgressView(value: Double(model.level)).progressViewStyle(.linear)
                }
                Text(model.microphone ? "Say something: the bar should move." : "Allow the microphone first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Speech model") {
                ModelRow(state: model.modelState, preparingSeconds: model.preparingSeconds)
            }
            Section("Try it") {
                Text("Click in the box, hold \((activeHotkey?.keys ?? listenKeys).map(\.label).joined(separator: " or ")), say a sentence, let go.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $model.tryText).frame(height: 80).font(.body)
            }
            Section {
                HStack {
                    Button("Open Settings…") { SettingsWindow.shared.show() }
                    Spacer()
                    Button("Done") {
                        try? LarynxCore.Settings.shared.set("true", for: .onboarded)
                        FirstRun.shared.close()
                    }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 620)
    }
}
