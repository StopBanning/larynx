import AppKit
import LarynxCore
import SwiftUI

/// Meeting mode's visible side (docs/dev/MEETING.md). Built for someone who should never have to wonder what is going
/// on: one big button to start, a panel that always says what is happening in plain words, and the notes opening by
/// themselves when they are ready.
@MainActor
final class MeetingController: ObservableObject {
    static let shared = MeetingController()

    enum Phase: Equatable { case idle, recording(Date), finishing(String), failed(String) }
    @Published var phase: Phase = .idle
    @Published var levels: (you: Float, call: Float) = (0, 0)
    @Published var callNote: String?
    @Published var micMuted = false

    private var capture: MeetingCapture?
    private var session: MeetingSession?
    private var stepper: Task<Void, Never>?
    private var ticker: Timer?
    private var id = ""
    private var started = Date()

    var isRecording: Bool { if case .recording = phase { return true }; return false }

    func toggle() { isRecording ? stop() : start() }

    /// Leaves the call recording and silences your side, for a noisy room or a call played through the speakers.
    func toggleMute() {
        micMuted.toggle()
        capture?.setMicMuted(micMuted)
    }

    func start() {
        guard !isRecording else { return }
        micMuted = false
        id = MeetingStore.newID()
        started = Date()
        let session = MeetingSession { samples in try await transcriber.transcribe(samples) }
        self.session = session
        do {
            let capture = try MeetingCapture(id: id) { samples, side in Task { await session.append(samples, side: side) } }
            try capture.start()
            self.capture = capture
            callNote = capture.callAudioError == nil ? nil : "Only your microphone is being recorded. To include the other people on a call, allow Larynx under System Settings → Privacy & Security → System Audio Recording."
        } catch {
            phase = .failed("I couldn't start recording: \(error.localizedDescription). Check that the microphone isn't muted and that Larynx is allowed to use it.")
            RecordingPanel.shared.show()
            return
        }
        phase = .recording(started)
        RecordingPanel.shared.show()
        // Keep the transcript caught up while the meeting runs, so stopping is quick.
        stepper = Task { [weak self] in
            try? await Loader.shared.task.value
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let s = self?.session else { return }
                try? await s.step()
            }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let c = self.capture else { return }
                self.levels = (c.level("You"), c.level("On the call"))
                self.objectWillChange.send()
            }
        }
    }

    func stop() {
        guard isRecording, let session else { return }
        ticker?.invalidate(); ticker = nil
        stepper?.cancel(); stepper = nil
        capture?.stop(); capture = nil
        let duration = Date().timeIntervalSince(started)
        phase = .finishing("Finishing the transcript…")
        let id = self.id, started = self.started
        Task {
            do {
                try await Loader.shared.task.value
                let segments = try await session.finish()
                var meeting = Meeting(id: id, started: started, duration: duration, segments: segments)
                if segments.isEmpty {
                    try? MeetingStore.save(meeting)
                    self.phase = .failed("I didn't hear anyone speak in this recording. If people were talking, check that the microphone isn't muted.")
                    return
                }
                self.phase = .finishing("Writing your summary… \(Self.estimate(duration))")
                let model = MeetingSummarizer.Model.chosen(Settings.shared.string(.meetingSummary))
                do {
                    meeting.notes = try await MeetingSummarizer.summarize(meeting, model: model)
                } catch {
                    // The transcript is still worth having: save it and say so plainly.
                    self.callNote = "The summary couldn't be written (\(error)). The full transcript is saved."
                }
                try MeetingStore.save(meeting)
                MeetingStore.removeSpool(id)
                self.phase = .idle
                RecordingPanel.shared.hide()
                MeetingsWindow.shared.show(selecting: meeting.id)
            } catch {
                self.phase = .failed("Something went wrong finishing the meeting: \(error). The recording is kept and can be finished later.")
            }
        }
    }

    func dismissFailure() { phase = .idle; RecordingPanel.shared.hide() }

    static func estimate(_ duration: Double) -> String {
        duration < 20 * 60 ? "about 10 seconds" : duration < 60 * 60 ? "about 20 seconds" : "under a minute"
    }
}

extension MeetingStore {
    static func removeSpool(_ id: String) {
        let folder = folder.appendingPathComponent("spool", isDirectory: true)
        for side in ["you", "call"] { try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(id)-\(side).f32")) }
    }
}

// MARK: - The recording panel

/// A floating panel at the top of the screen while a meeting records: a red dot, the time, the two sides' levels and
/// one big Stop button. Never takes focus away from the call.
@MainActor
final class RecordingPanel {
    static let shared = RecordingPanel()
    private var panel: NSPanel?

    func show() {
        if panel == nil {
            // Borderless and clear: the view draws its own glass (macOS 26) or frosted blur, and casts its own shadow.
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 150),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.isMovableByWindowBackground = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: RecordingView(controller: MeetingController.shared))
            host.wantsLayer = true
            host.layer?.backgroundColor = .clear
            p.contentView = host
            panel = p
        }
        if let screen = NSScreen.main, let p = panel {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.maxY - p.frame.height - 12))
        }
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

struct RecordingView: View {
    @ObservedObject var controller: MeetingController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch controller.phase {
            case .recording(let since):
                HStack(spacing: 12) {
                    Circle().fill(Color.red).frame(width: 14, height: 14)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Recording · \(Meeting.clock(context.date.timeIntervalSince(since)))")
                            .font(.system(size: 22, weight: .semibold)).monospacedDigit()
                    }
                    Spacer()
                    Button(action: { controller.stop() }) {
                        Text("Stop").font(.system(size: 18, weight: .semibold)).frame(minWidth: 72, minHeight: 34)
                    }
                    .glassButton(prominent: true)
                    .tint(.red)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                }
                HStack(spacing: 14) {
                    Meter(label: controller.micMuted ? "Muted" : "You", level: controller.micMuted ? 0 : controller.levels.you,
                          off: controller.micMuted)
                    Meter(label: "The call", level: controller.levels.call)
                    Button(action: { controller.toggleMute() }) {
                        Label(controller.micMuted ? "Unmute" : "Mute me",
                              systemImage: controller.micMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 14, weight: .medium))
                            .frame(minHeight: 22)
                    }
                    .glassButton(prominent: false)
                    .tint(controller.micMuted ? .orange : nil)
                    .fixedSize()
                    .help(controller.micMuted ? "Record your microphone again" : "Keep recording the call, but not your microphone")
                }
                if let note = controller.callNote {
                    Text(note).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            case .finishing(let message):
                HStack(spacing: 12) {
                    ProgressView().controlSize(.regular)
                    Text(message).font(.system(size: 20, weight: .semibold))
                }
                Text("Your notes will open here by themselves.").font(.system(size: 14)).foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).font(.system(size: 16)).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("OK") { controller.dismissFailure() }.controlSize(.large).keyboardShortcut(.defaultAction) }
            case .idle:
                EmptyView()
            }
        }
        .padding(20)
        .frame(width: 420)
        .panelGlass(cornerRadius: 26)
        .padding(10)  // room for the shadow inside the clear panel
    }
}

extension View {
    /// Liquid Glass behind the recording panel on macOS 26, a frosted blur with a shadow before that.
    @ViewBuilder func panelGlass(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        }
    }

    /// Glass buttons on macOS 26 (prominent ones take the tint), the ordinary bordered style before that.
    @ViewBuilder func glassButton(prominent: Bool) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
}

struct Meter: View {
    let label: String
    let level: Float
    var off = false
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    if !off {
                        Capsule().fill(Color.green).frame(width: max(4, g.size.width * CGFloat(min(1, level * 3))))
                    }
                }
            }
            .frame(height: 8)
        }
    }
}

// MARK: - The meetings window

/// Every meeting, newest first, and the one chosen in full: its notes in large type, then the transcript. Buttons for
/// what comes next: Email this to me, Copy, Print.
@MainActor
final class MeetingsWindow {
    static let shared = MeetingsWindow()
    private var window: NSWindow?
    let model = MeetingsModel()

    func show(selecting id: String? = nil) {
        model.reload()
        if let id { model.selected = id } else if model.selected == nil { model.selected = model.meetings.first?.id }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Larynx Meetings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: MeetingsView(model: model))
            w.center()
            w.setFrameAutosaveName("LarynxMeetings")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class MeetingsModel: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var selected: String?
    @Published var showTranscript = false

    @Published var writing: String?
    @Published var writeFailure: [String: String] = [:]

    func reload() { meetings = MeetingStore.all() }

    /// Writes the notes again for a meeting that has none (the internet was down, or the key was added later).
    func writeNotes(_ m: Meeting) {
        guard writing == nil else { return }
        writing = m.id; writeFailure[m.id] = nil
        Task {
            var meeting = m
            do {
                meeting.notes = try await MeetingSummarizer.summarize(meeting, model: MeetingSummarizer.Model.chosen(Settings.shared.string(.meetingSummary)))
                try MeetingStore.save(meeting)
                reload()
            } catch { writeFailure[m.id] = "\(error)" }
            writing = nil
        }
    }
    var current: Meeting? { meetings.first { $0.id == selected } }

    func copy(_ m: Meeting) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(m.markdown, forType: .string)
    }

    /// Opens Mail with the notes (the transcript stays in Larynx: a long transcript makes a mail nobody reads).
    func email(_ m: Meeting) {
        var notesOnly = m; notesOnly.segments = []
        let body = notesOnly.markdown.replacingOccurrences(of: "\n## Transcript\n", with: "")
        let to = Settings.shared.string(.meetingEmail)
        var c = URLComponents(); c.scheme = "mailto"; c.path = to
        c.queryItems = [URLQueryItem(name: "subject", value: m.notes?.title ?? "Meeting notes"), URLQueryItem(name: "body", value: body)]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    func print(_ m: Meeting) {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 800))
        view.string = m.markdown.replacingOccurrences(of: "**", with: "")
        view.font = NSFont.systemFont(ofSize: 13)
        NSPrintOperation(view: view).run()
    }
}

struct MeetingsView: View {
    @ObservedObject var model: MeetingsModel

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $model.selected) {
                if model.meetings.isEmpty {
                    Text("No meetings yet. Choose Start Recording a Meeting in the Larynx menu.").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                ForEach(model.meetings, id: \.id) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.notes?.title ?? "Meeting").font(.system(size: 15, weight: .semibold)).lineLimit(2)
                        Text(DateFormatter.localizedString(from: m.started, dateStyle: .medium, timeStyle: .short) + " · \(max(1, Int((m.duration / 60).rounded()))) min")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .tag(m.id)
                }
            }
            .frame(width: 260)
            Divider()
            if let m = model.current { MeetingDetail(meeting: m, model: model) } else {
                VStack { Spacer(); Text("Choose a meeting").font(.system(size: 18)).foregroundStyle(.secondary); Spacer() }.frame(maxWidth: .infinity)
            }
        }
    }
}

struct MeetingDetail: View {
    let meeting: Meeting
    @ObservedObject var model: MeetingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(meeting.notes?.title ?? "Meeting").font(.system(size: 28, weight: .bold))
                    Text(DateFormatter.localizedString(from: meeting.started, dateStyle: .full, timeStyle: .short)
                         + " · \(max(1, Int((meeting.duration / 60).rounded()))) minutes")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button { model.email(meeting) } label: { Label("Email this to me", systemImage: "envelope").font(.system(size: 15)) }.controlSize(.large)
                    Button { model.copy(meeting) } label: { Label("Copy", systemImage: "doc.on.doc").font(.system(size: 15)) }.controlSize(.large)
                    Button { model.print(meeting) } label: { Label("Print", systemImage: "printer").font(.system(size: 15)) }.controlSize(.large)
                }
                if let n = meeting.notes {
                    Section(title: "Summary", items: n.summary)
                    if !n.decisions.isEmpty { Section(title: "Decisions", items: n.decisions) }
                    if !n.actionItems.isEmpty {
                        Section(title: "To do", items: n.actionItems.map { item in
                            var line = item.task
                            if let o = item.owner { line += " (\(o)" + (item.due.map { ", \($0)" } ?? "") + ")" }
                            else if let d = item.due { line += " (\(d))" }
                            return line
                        })
                    }
                    if !n.openQuestions.isEmpty { Section(title: "Still open", items: n.openQuestions) }
                    if n.model == "claude" { Text("Summary written by Claude.").font(.system(size: 13)).foregroundStyle(.secondary) }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("There's no summary for this meeting yet. The full transcript is below.").font(.system(size: 16)).foregroundStyle(.secondary)
                        if model.writing == meeting.id {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Writing the summary…").font(.system(size: 16)) }
                        } else {
                            Button { model.writeNotes(meeting) } label: { Label("Write the summary now", systemImage: "text.badge.star").font(.system(size: 15)) }
                                .controlSize(.large)
                        }
                        if let why = model.writeFailure[meeting.id] { Text(why).font(.system(size: 15)).foregroundStyle(.red) }
                    }
                }
                DisclosureGroup(isExpanded: $model.showTranscript) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(meeting.segments.enumerated()), id: \.offset) { _, s in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(s.speaker) · \(Meeting.clock(s.start))").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                                Text(s.text).font(.system(size: 16)).textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Everything that was said").font(.system(size: 18, weight: .semibold))
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    struct Section: View {
        let title: String
        let items: [String]
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 20, weight: .semibold))
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("•").font(.system(size: 17))
                        Text(item).font(.system(size: 17)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
