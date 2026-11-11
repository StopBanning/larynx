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

    /// Live status every second while the window is open, and the level meter once the microphone is allowed.
    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                FirstRunModel.shared.refresh()
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

struct FirstRunView: View {
    @ObservedObject private var model = FirstRunModel.shared
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Talk anywhere. Nothing leaves your Mac.").font(.title3.bold())
                    Text("Three permissions, then hold a key and speak. Apple Silicon only.").foregroundStyle(.secondary)
                }
            }
            Section("Permissions") {
                StepRow(done: model.microphone, title: "Microphone", detail: "To hear you while you hold the talk key.",
                        button: "Allow") {
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else { FirstRunModel.openPane("Privacy_Microphone") }
                }
                StepRow(done: model.inputMonitoring, title: "Input Monitoring", detail: "To notice the talk key from any app.",
                        button: "Open Settings") { Hotkey.requestListen(); FirstRunModel.openPane("Privacy_ListenEvent") }
                StepRow(done: model.accessibility, title: "Accessibility", detail: "To paste your words where the cursor is.",
                        button: "Open Settings") { Inserter.requestTrust(); FirstRunModel.openPane("Privacy_Accessibility") }
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
                StepRow(done: model.modelReady, title: model.modelReady ? "Ready" : "Downloading (about 500 MB, once)",
                        detail: "Runs on this Mac's Neural Engine. The very first load takes a minute or two while macOS prepares it.",
                        button: "") {}
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
