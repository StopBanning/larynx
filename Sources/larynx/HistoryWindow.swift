import AppKit
import AVFoundation
import LarynxCore
import LarynxText
import SwiftUI

/// The History window (PLAN-v1 R5): everything you dictated in the last 30 days, on this Mac only. Search it, copy
/// a dictation again, hear the recording when one was kept, and fix one that came out wrong: the fix is saved, and
/// a changed word that sounds like what was typed is learned for next time.
@MainActor
final class HistoryWindow {
    static let shared = HistoryWindow()
    private var window: NSWindow?

    /// `fixLast`: open with the newest dictation ready to edit (the menu's "Fix Last Dictation…").
    func show(fixLast: Bool = false) {
        let model = HistoryModel.shared
        model.reload()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Larynx History"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: HistoryView(model: model))
            w.center()
            w.setFrameAutosaveName("LarynxHistory")
            window = w
        }
        if fixLast, let newest = model.newest { model.beginFix(newest) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// What the window shows. No SwiftUI macros (this builds with the command-line tools).
@MainActor
final class HistoryModel: ObservableObject {
    static let shared = HistoryModel(history: .shared)

    struct Day: Identifiable { let id: String; let title: String; var rows: [History.Row] }
    struct Stats { var count = 0, words = 0; var seconds = 0.0 }

    @Published var query = ""
    @Published private(set) var days: [Day] = []
    @Published private(set) var fixes: [String: String] = [:]
    @Published private(set) var notes: [String: String] = [:]
    @Published private(set) var playing: String?
    @Published private(set) var stats = Stats()
    @Published var editing: String?
    @Published var draft = ""

    private let history: History?
    private var all: [History.Row] = []
    private var player: AVAudioPlayer?

    init(history: History?) { self.history = history }

    /// For the layout snapshot: made-up rows, no database.
    init(rows: [History.Row], fixes: [String: String] = [:], notes: [String: String] = [:], editing: String? = nil, now: Date) {
        history = nil
        all = rows
        self.fixes = fixes
        self.notes = notes
        self.editing = editing
        if let editing, let row = rows.first(where: { $0.id == editing }) { draft = fixes[row.id] ?? row.text }
        stats = Self.stats(rows)
        days = Self.group(rows, now: now)
    }

    var newest: History.Row? { all.first }
    var isEmpty: Bool { all.isEmpty }
    var historyIsOff: Bool { Settings.shared.string(.history) == "off" }

    func reload() {
        guard let history else { return }
        all = history.recent(limit: 5000)
        fixes = history.corrections().mapValues(\.text)
        stats = Self.stats(all)
        search()
    }

    func search() {
        let words = query.trimmingCharacters(in: .whitespaces)
        let rows = words.isEmpty ? all : (history?.search(words, limit: 300) ?? all.filter { $0.text.localizedCaseInsensitiveContains(words) })
        days = Self.group(rows, now: Date())
    }

    /// The dictation as it should read: your fix when there is one.
    func text(_ row: History.Row) -> String { fixes[row.id] ?? row.text }

    func copy(_ row: History.Row) {
        Inserter.copyOnly(text(row))
        notes[row.id] = "Copied. Press ⌘V where you want it."
    }

    func hasAudio(_ row: History.Row) -> Bool { row.audioPath.map { FileManager.default.fileExists(atPath: $0) } ?? false }

    func togglePlay(_ row: History.Row) {
        if playing == row.id { player?.stop(); playing = nil; return }
        guard let path = row.audioPath, let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else { return }
        player?.stop()
        player = p
        p.play()
        playing = row.id
        let id = row.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((p.duration + 0.2) * 1_000_000_000))
            if self?.playing == id, self?.player === p { self?.playing = nil }
        }
    }

    func beginFix(_ row: History.Row) {
        draft = text(row)
        editing = row.id
    }

    func cancelFix() { editing = nil }

    func saveFix(_ row: History.Row) {
        defer { editing = nil }
        guard let history else { return }
        let fixed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Compare with what Larynx typed, not with an earlier fix: the lesson is about what the speech model heard.
        let out = HistoryFix.apply(row, fixed: fixed, history: history, words: MacWordList())
        guard out.saved else { return }
        fixes[row.id] = fixed
        let learning = Settings.shared.string(.learn) != "off"
        let applied = learning ? Relearn.apply(out.lessons) : []
        if !applied.isEmpty { Task { await reloadVocabulary() } }
        let suggested = out.lessons.contains { if case .suggestion = $0 { return true }; return false }
        if !applied.isEmpty {
            notes[row.id] = "Saved. Larynx learned: " + Relearn.describe(applied)
        } else if suggested {
            notes[row.id] = "Saved. Both are real words, so Larynx won't swap them by itself."
        } else {
            notes[row.id] = "Saved."
        }
        // Said in the window, because it outlives the usual keepAudio period (docs/PRIVACY.md).
        if out.addedToGolden { notes[row.id, default: ""] += " The recording is kept as a test clip until you remove it." }
        log("history fix: \(applied.count) lesson\(applied.count == 1 ? "" : "s")\(out.addedToGolden ? ", recording added to the golden set" : "")")
    }

    static func stats(_ rows: [History.Row]) -> Stats {
        Stats(count: rows.count, words: rows.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count },
              seconds: rows.reduce(0) { $0 + $1.audioSeconds })
    }

    static func group(_ rows: [History.Row], now: Date) -> [Day] {
        let calendar = Calendar.current
        let named = DateFormatter()
        named.dateFormat = "EEEE, MMMM d"
        var days: [Day] = []
        for row in rows {
            let start = calendar.startOfDay(for: row.time)
            let key = String(Int(start.timeIntervalSince1970))
            if days.last?.id == key { days[days.count - 1].rows.append(row); continue }
            let ago = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: now)).day ?? 0
            days.append(Day(id: key, title: ago == 0 ? "Today" : ago == 1 ? "Yesterday" : named.string(from: start), rows: [row]))
        }
        return days
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search what you said", text: $model.query).textFieldStyle(.plain)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear the search")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .padding(12)
            .onChange(of: model.query) { model.search() }
            Divider()
            if model.days.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: model.isEmpty ? "waveform" : "magnifyingglass").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text(emptyText).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(model.days) { day in
                            Section {
                                ForEach(day.rows, id: \.id) { row in
                                    HistoryRowView(row: row, model: model)
                                    Divider().padding(.leading, 46)
                                }
                            } header: {
                                Text(day.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14).padding(.vertical, 6).background(.bar)
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text(statsText)
                Spacer()
                Text("On this Mac only").help("History never leaves your Mac. Settings › Privacy sets how long it is kept.")
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    var emptyText: String {
        if !model.isEmpty { return "No dictation matches “\(model.query)”." }
        if model.historyIsOff { return "History is off.\nTurn it on in Settings › Privacy to keep what you dictate." }
        return "Nothing yet.\nHold your talk key and say something."
    }

    /// Counted from what is kept, on this Mac. "Typing saved" compares the words with typing them at 40 words a minute.
    var statsText: String {
        let s = model.stats
        guard s.count > 0 else { return "" }
        let number = NumberFormatter()
        number.numberStyle = .decimal
        func n(_ v: Int) -> String { number.string(from: NSNumber(value: v)) ?? "\(v)" }
        var parts = ["\(n(s.count)) dictation\(s.count == 1 ? "" : "s")", "\(n(s.words)) words", Self.duration(s.seconds) + " of talking"]
        let saved = Double(s.words) / 40 * 60 - s.seconds
        if saved >= 60 { parts.append("about " + Self.duration(saved) + " of typing saved") }
        return parts.joined(separator: " · ")
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "\(Int(seconds.rounded())) s" }
        if minutes < 90 { return "\(minutes) min" }
        return String(format: "%.1f h", seconds / 3600)
    }
}

private struct HistoryRowView: View {
    let row: History.Row
    @ObservedObject var model: HistoryModel

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: AppLook.icon(row.app)).resizable().frame(width: 22, height: 22).padding(.top, 1)
                .help(AppLook.name(row.app))
            VStack(alignment: .leading, spacing: 5) {
                if model.editing == row.id { editor } else { reading }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    @ViewBuilder var reading: some View {
        Text(model.text(row)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        if let fixed = model.fixes[row.id], fixed != row.text {
            Text("Larynx typed: " + row.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                .help(row.text)
        }
        HStack(spacing: 10) {
            Text(Self.clock.string(from: row.time) + " · " + AppLook.name(row.app) + " · " + HistoryView.duration(row.audioSeconds))
                .foregroundStyle(.secondary)
            ForEach(tags, id: \.text) { tag in
                Label(tag.text, systemImage: tag.symbol).foregroundStyle(tag.color).help(tag.help)
            }
            Spacer(minLength: 0)
            if model.hasAudio(row) {
                Button { model.togglePlay(row) } label: { Image(systemName: model.playing == row.id ? "stop.fill" : "play.fill") }
                    .buttonStyle(.borderless).help(model.playing == row.id ? "Stop" : "Play the recording")
            }
            Button { model.copy(row) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy")
            Button("Fix…") { model.beginFix(row) }
                .buttonStyle(.borderless).help("This came out wrong: type what you said")
        }
        .font(.caption)
        if let note = model.notes[row.id] {
            Text(note).font(.caption).foregroundStyle(.green)
        }
    }

    @ViewBuilder var editor: some View {
        TextEditor(text: $model.draft)
            .font(.body).frame(minHeight: 54, maxHeight: 160).scrollContentBackground(.hidden)
            .padding(5).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        HStack {
            Text("Type what you said. A changed word that sounds like the old one is learned.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { model.cancelFix() }.keyboardShortcut(.cancelAction)
            Button("Save") { model.saveFix(row) }.keyboardShortcut(.defaultAction)
        }
    }

    struct Tag { let text: String; let symbol: String; let color: Color; let help: String }

    var tags: [Tag] {
        var out: [Tag] = []
        if model.fixes[row.id] != nil { out.append(Tag(text: "Fixed", symbol: "checkmark.circle", color: .green, help: "You fixed this one")) }
        if row.flags.contains("doubtful") {
            out.append(Tag(text: "Not sure", symbol: "questionmark.circle", color: .orange, help: "The speech model was unsure of a word here"))
        }
        if row.flags.contains("undone") { out.append(Tag(text: "Undone", symbol: "arrow.uturn.backward", color: .secondary, help: "You said “scratch that”")) }
        if row.flags.contains("recovered") {
            out.append(Tag(text: "Recovered", symbol: "lifepreserver", color: .secondary, help: "Saved from a dictation that was interrupted"))
        }
        if row.delivery == "copied" {
            out.append(Tag(text: "Clipboard", symbol: "clipboard", color: .secondary, help: "It could not be typed into the app, so it went to the clipboard"))
        }
        return out
    }
}

/// App names and icons by bundle id, looked up once each.
@MainActor
private enum AppLook {
    static var names: [String: String] = [:]
    static var icons: [String: NSImage] = [:]
    static let generic = NSWorkspace.shared.icon(for: .application)

    static func url(_ bundle: String?) -> URL? { bundle.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } }

    static func name(_ bundle: String?) -> String {
        guard let bundle else { return "Unknown app" }
        if let known = names[bundle] { return known }
        let name = url(bundle).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? bundle.split(separator: ".").last.map(String.init) ?? bundle
        names[bundle] = name
        return name
    }

    static func icon(_ bundle: String?) -> NSImage {
        guard let bundle else { return generic }
        if let known = icons[bundle] { return known }
        let icon = url(bundle).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? generic
        icons[bundle] = icon
        return icon
    }
}

/// Renders the window off-screen to PNGs in `dir` with made-up dictations (layout check and README pictures; never
/// your own history): `larynx history-snapshot <dir>`.
@MainActor func snapshotHistory(to dir: String) {
    let now = Date()
    func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }
    let rows = [
        History.Row(id: "d1", time: at(2), app: "com.apple.mail", text: "Hi Priya, the draft is attached. Could you look at section 3 before Thursday?", audioSeconds: 6.2),
        History.Row(id: "d2", time: at(9), app: "com.apple.Notes", text: "Ask Zorvex to rerun the build once the tests pass.", audioSeconds: 3.9, flags: ["doubtful"]),
        History.Row(id: "d3", time: at(31), app: "com.apple.Terminal", text: "git commit -m \"fix the retry loop\"", audioSeconds: 2.8),
        History.Row(id: "d4", time: at(64), app: "com.apple.MobileSMS", text: "Running about 10 minutes late, order me a flat white?", audioSeconds: 3.4),
        History.Row(id: "d5", time: at(26 * 60), app: "com.apple.Safari",
                    text: "The second option is cheaper up front, but the first one includes support for 3 years, so over that time it costs about $400 less.",
                    audioSeconds: 9.7),
        History.Row(id: "d6", time: at(27 * 60), app: "com.apple.Notes", text: "Remember to book the dentist.", audioSeconds: 1.9, delivery: "copied"),
    ]
    let shots: [(String, HistoryModel)] = [
        ("history", HistoryModel(rows: rows, fixes: ["d2": "Ask Zorbax to rerun the build once the tests pass."],
                                 notes: ["d2": "Saved. Larynx learned: Zorvex → Zorbax"], now: now)),
        ("history-fix", HistoryModel(rows: rows, editing: "d2", now: now)),
    ]
    for (name, model) in shots {
        // An off-screen view has no window behind it, so the background is drawn here, in a fixed light appearance.
        let host = NSHostingView(rootView: HistoryView(model: model).frame(width: 640, height: 560)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 560)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
}
