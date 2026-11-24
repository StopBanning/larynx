import Foundation
import LarynxText

/// Meeting mode (docs/MEETINGS.md): a meeting is two tracks of audio, the microphone ("You") and the call ("Them"),
/// cut into utterances where each side speaks, transcribed piece by piece and summarized at the end.

public struct MeetingSegment: Codable, Sendable, Equatable {
    public var speaker: String
    /// Seconds from the start of the meeting.
    public var start: Double
    public var end: Double
    public var text: String
    public init(speaker: String, start: Double, end: Double, text: String) {
        self.speaker = speaker; self.start = start; self.end = end; self.text = text
    }
}

public struct MeetingActionItem: Codable, Sendable, Equatable {
    public var task: String
    /// Only when someone said who; never guessed.
    public var owner: String?
    /// Only when someone said when.
    public var due: String?
    public init(task: String, owner: String? = nil, due: String? = nil) { self.task = task; self.owner = owner; self.due = due }
}

public struct MeetingNotes: Codable, Sendable, Equatable {
    public var title: String
    public var summary: [String]
    public var decisions: [String]
    public var actionItems: [MeetingActionItem]
    public var openQuestions: [String]
    /// Which model wrote them ("on-device", "private-cloud") and how long it took.
    public var model: String
    public var seconds: Double
    public init(title: String, summary: [String], decisions: [String], actionItems: [MeetingActionItem],
                openQuestions: [String], model: String, seconds: Double) {
        self.title = title; self.summary = summary; self.decisions = decisions; self.actionItems = actionItems
        self.openQuestions = openQuestions; self.model = model; self.seconds = seconds
    }
}

public struct Meeting: Codable, Sendable {
    public var id: String
    public var started: Date
    public var duration: Double
    public var segments: [MeetingSegment]
    public var notes: MeetingNotes?
    public init(id: String, started: Date, duration: Double, segments: [MeetingSegment], notes: MeetingNotes? = nil) {
        self.id = id; self.started = started; self.duration = duration; self.segments = segments; self.notes = notes
    }

    public var speakers: [String] {
        var seen: [String] = []
        for s in segments where !seen.contains(s.speaker) { seen.append(s.speaker) }
        return seen
    }

    /// The transcript as the summarizer reads it: one line per utterance, "[mm:ss] Speaker: text".
    public var transcriptText: String {
        segments.map { "[\(Meeting.clock($0.start))] \($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    public static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// The meeting as Markdown: what Copy and Export hand over.
    public var markdown: String {
        var out: [String] = []
        let date = DateFormatter.localizedString(from: started, dateStyle: .medium, timeStyle: .short)
        out.append("# \(notes?.title ?? "Meeting")")
        out.append("\(date) · \(Int((duration / 60).rounded())) min · \(speakers.joined(separator: ", "))")
        if let n = notes {
            out.append("\n## Summary\n" + n.summary.map { "- \($0)" }.joined(separator: "\n"))
            if !n.decisions.isEmpty { out.append("\n## Decisions\n" + n.decisions.map { "- \($0)" }.joined(separator: "\n")) }
            if !n.actionItems.isEmpty {
                out.append("\n## Action items\n" + n.actionItems.map { item in
                    var line = "- [ ] \(item.task)"
                    if let o = item.owner { line += " (\(o)" + (item.due.map { ", \($0)" } ?? "") + ")" }
                    else if let d = item.due { line += " (\(d))" }
                    return line
                }.joined(separator: "\n"))
            }
            if !n.openQuestions.isEmpty { out.append("\n## Open questions\n" + n.openQuestions.map { "- \($0)" }.joined(separator: "\n")) }
        }
        out.append("\n## Transcript\n" + segments.map { "**\($0.speaker)** \(Meeting.clock($0.start))  \n\($0.text)" }.joined(separator: "\n\n"))
        return out.joined(separator: "\n")
    }
}

/// Where each side speaks: stretches of audio louder than the track's own quiet level, joined across short pauses and
/// cut into pieces of at most `maxLength` seconds at the quietest moment, so no word is cut in half.
public enum Utterances {
    public static func split(_ samples: [Float], rate: Double = 16_000, maxLength: Double = 28,
                             minPause: Double = 0.7, minSpeech: Double = 0.35) -> [(start: Double, end: Double)] {
        let frame = Int(rate * 0.02)  // 20 ms
        guard samples.count >= frame else { return [] }
        let frames = samples.count / frame
        var energy = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            var sum: Float = 0
            for j in (i * frame)..<((i + 1) * frame) { sum += samples[j] * samples[j] }
            energy[i] = (sum / Float(frame)).squareRoot()
        }
        // The floor is the track's quiet level (its 20th percentile), the threshold a few times above it, with an
        // absolute minimum so a silent track stays silent.
        let sorted = energy.sorted()
        let floor = sorted[Int(Double(sorted.count) * 0.2)]
        let peak = sorted[Int(Double(sorted.count) * 0.98)]
        let threshold = max(0.004, floor * 3, floor + (peak - floor) * 0.08)
        var voiced = energy.map { $0 > threshold }
        // Bridge pauses shorter than minPause.
        let bridge = Int(minPause / 0.02)
        var i = 0
        while i < frames {
            if !voiced[i] {
                var j = i
                while j < frames && !voiced[j] { j += 1 }
                if i > 0 && j < frames && j - i < bridge { for k in i..<j { voiced[k] = true } }
                i = j
            } else { i += 1 }
        }
        var spans: [(Int, Int)] = []
        i = 0
        while i < frames {
            if voiced[i] {
                var j = i
                while j < frames && voiced[j] { j += 1 }
                if Double(j - i) * 0.02 >= minSpeech { spans.append((i, j)) }
                i = j
            } else { i += 1 }
        }
        // Long spans are cut at the quietest 200 ms near each limit.
        let limit = Int(maxLength / 0.02)
        var out: [(Double, Double)] = []
        for (a, b) in spans {
            var s = a
            while b - s > limit {
                let lo = s + limit * 2 / 3, hi = min(s + limit, b)
                var best = lo, bestEnergy = Float.greatestFiniteMagnitude
                for k in lo..<max(lo + 1, hi - 10) {
                    let e = energy[k..<min(k + 10, frames)].reduce(0, +)
                    if e < bestEnergy { bestEnergy = e; best = k + 5 }
                }
                out.append((Double(s) * 0.02, Double(best) * 0.02))
                s = best
            }
            out.append((Double(s) * 0.02, Double(b) * 0.02))
        }
        // A little air around each piece so the first and last sounds are whole.
        let total = Double(samples.count) / rate
        return out.map { (max(0, $0.0 - 0.15), min(total, $0.1 + 0.2)) }
    }
}

/// Saved meetings: ~/Library/Application Support/Larynx/meetings/<id>.json and .md (moved by LARYNX_DATA_DIR).
public enum MeetingStore {
    public static var folder: URL {
        let base = ProcessInfo.processInfo.environment["LARYNX_DATA_DIR"]
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Larynx")
        return base.appendingPathComponent("meetings", isDirectory: true)
    }

    public static func newID(_ date: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    @discardableResult
    public static func save(_ meeting: Meeting) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let json = folder.appendingPathComponent("\(meeting.id).json")
        try encoder.encode(meeting).write(to: json, options: .atomic)
        try Data(meeting.markdown.utf8).write(to: folder.appendingPathComponent("\(meeting.id).md"), options: .atomic)
        return json
    }

    public static func all() -> [Meeting] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Meeting.self, from: Data(contentsOf: $0)) }
            .sorted { $0.started > $1.started }
    }
}

/// Turns the two tracks into the meeting's transcript: each side's utterances transcribed on their own, cleaned like a
/// dictation for people (fillers, stutters and false starts out, nothing rewritten), then put in time order.
public enum MeetingTranscriber {
    public static func segments(you: [Float], them: [Float]?, rate: Double = 16_000,
                                youName: String = "You", themName: String = "On the call",
                                transcribe: ([Float]) async throws -> String) async throws -> [MeetingSegment] {
        var out: [MeetingSegment] = []
        for (track, name) in [(you, youName)] + (them.map { [($0, themName)] } ?? []) {
            for span in Utterances.split(track, rate: rate) {
                let a = Int(span.start * rate), b = min(track.count, Int(span.end * rate))
                guard b - a > Int(rate * 0.3) else { continue }
                let raw = try await transcribe(Array(track[a..<b])).trimmingCharacters(in: .whitespacesAndNewlines)
                let text = Numbers.apply(Tidy.apply(raw, mode: .correspondence))
                guard text.rangeOfCharacter(from: .alphanumerics) != nil else { continue }
                out.append(MeetingSegment(speaker: name, start: span.start, end: span.end, text: text))
            }
        }
        return out.sorted { $0.start < $1.start }
    }
}

/// Transcribes a meeting while it is still going, so stopping only has to finish the last few seconds and write the
/// notes. Audio is appended per side as it arrives; `step()` transcribes every utterance that has clearly ended (a pause
/// after it, or the 28-second limit) and keeps the rest for later. `finish()` transcribes whatever is left.
public actor MeetingSession {
    public let rate: Double
    private var tracks: [String: [Float]] = [:]
    private var done: [String: Int] = [:]          // samples already turned into segments, per side
    public private(set) var segments: [MeetingSegment] = []
    private let transcribe: @Sendable ([Float]) async throws -> String

    public init(rate: Double = 16_000, transcribe: @escaping @Sendable ([Float]) async throws -> String) {
        self.rate = rate; self.transcribe = transcribe
    }

    public func append(_ samples: [Float], side: String) { tracks[side, default: []].append(contentsOf: samples) }

    public var duration: Double { Double(tracks.values.map(\.count).max() ?? 0) / rate }

    public func samples(side: String) -> [Float] { tracks[side] ?? [] }

    /// Transcribes the utterances that have ended. With `final`, everything that is left.
    public func step(final: Bool = false) async throws {
        for side in tracks.keys.sorted() {
            let track = tracks[side] ?? []
            let from = done[side] ?? 0
            guard track.count > from else { continue }
            let pending = Array(track[from...])
            var spans = Utterances.split(pending, rate: rate)
            // An utterance still running at the end of the audio may not be finished: wait for more, unless final.
            if !final, let last = spans.last, Double(pending.count) / rate - last.end < 0.6 { spans.removeLast() }
            for span in spans {
                let a = Int(span.start * rate), b = min(pending.count, Int(span.end * rate))
                guard b - a > Int(rate * 0.3) else { continue }
                let raw = try await transcribe(Array(pending[a..<b])).trimmingCharacters(in: .whitespacesAndNewlines)
                let text = Numbers.apply(Tidy.apply(raw, mode: .correspondence))
                if text.rangeOfCharacter(from: .alphanumerics) != nil {
                    let offset = Double(from) / rate
                    segments.append(MeetingSegment(speaker: side, start: offset + span.start, end: offset + span.end, text: text))
                }
            }
            if final { done[side] = track.count }
            else if let last = spans.last { done[side] = from + min(pending.count, Int(last.end * rate)) }
        }
        segments.sort { $0.start < $1.start }
    }

    public func finish() async throws -> [MeetingSegment] {
        try await step(final: true)
        return MeetingEcho.remove(segments)
    }
}

/// The call heard twice: with no headphones, the microphone picks up the call from the speakers, and those lines land
/// in the transcript as "You". A "You" line is an echo when most of its words were said on the call while it played
/// (it overlaps a call line for at least half its length and 60% of its words match), or, just after a call line, when
/// it has three or more words and nearly all of them match. A real reply comes after the call has spoken and is rarely
/// a copy, so it stays ("Let's stay with the standard stock" after "the standard stock saves two thousand"). Short
/// garbled echoes can slip through; the rule would rather keep an echo than lose something you said.
public enum MeetingEcho {
    public static func remove(_ segments: [MeetingSegment], you: String = "You") -> [MeetingSegment] {
        let call = segments.filter { $0.speaker != you }
        guard !call.isEmpty else { return segments }
        return segments.filter { s in s.speaker != you || !isEcho(s, call: call) }
    }

    static func isEcho(_ s: MeetingSegment, call: [MeetingSegment]) -> Bool {
        let ws = words(s.text)
        guard !ws.isEmpty else { return false }
        var during: Set<String> = [], near: Set<String> = [], overlap = 0.0
        for c in call {
            let o = min(s.end, c.end) - max(s.start, c.start)
            if o > 0 { overlap += o; during.formUnion(words(c.text)) }
            if c.start - 1.5 <= s.start && s.start <= c.end + 1.5 { near.formUnion(words(c.text)) }
        }
        func share(_ pool: Set<String>) -> Double { Double(ws.filter { matches($0, pool) }.count) / Double(ws.count) }
        if overlap >= 0.5 * (s.end - s.start) && share(during) >= 0.6 { return true }
        return ws.count >= 3 && share(near) >= 0.85
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
            .split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// The same word, or one the speech model heard a little differently from the speakers ("carweave", "coreweave").
    static func matches(_ w: String, _ pool: Set<String>) -> Bool {
        if pool.contains(w) { return true }
        guard w.count >= 4 else { return false }
        return pool.contains { p in p.count >= 4 && (p.prefix(4) == w.prefix(4) || similarity(w, p) >= 0.75) }
    }

    /// Like Python's difflib ratio, simplified: twice the longest common subsequence over the total length.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        var prev = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            var cur = [Int](repeating: 0, count: y.count + 1)
            for j in 1...y.count { cur[j] = x[i - 1] == y[j - 1] ? prev[j - 1] + 1 : max(prev[j], cur[j - 1]) }
            prev = cur
        }
        return 2 * Double(prev[y.count]) / Double(x.count + y.count)
    }
}

extension Meeting {
    /// The names "You" addressed in the meeting ("Go ahead, Dana.", "Dana, any good candidates?", "Thanks, Priya"), in
    /// the order first said. Words that start sentences ("Great,", "Okay,") are not names.
    public var addressedNames: [String] {
        let notNames: Set<String> = ["okay", "ok", "great", "thanks", "thank", "morning", "yes", "yeah", "fine", "right", "last", "perfect",
                                     "so", "well", "sure", "good", "hi", "hey", "hello", "alright", "no", "wait", "sorry", "please",
                                     "actually", "anyway", "also", "then", "now", "first", "next", "everyone", "guys", "folks", "all",
                                     "afternoon", "evening", "cool", "nice", "awesome", "exactly", "true", "agreed", "absolutely", "anyone"]
        guard let re = try? NSRegularExpression(pattern: "(?:^|[,.!?]\\s+)([A-Z][a-z]{1,15})(?=[,.!?])") else { return [] }
        var names: [String] = []
        for seg in segments where seg.speaker == "You" {
            let ns = seg.text as NSString
            for m in re.matches(in: seg.text, range: NSRange(location: 0, length: ns.length)) {
                let w = ns.substring(with: m.range(at: 1))
                if !notNames.contains(w.lowercased()), !names.contains(w) { names.append(w) }
            }
        }
        return names
    }

    /// When "You" spoke to exactly one person by name, everyone on the call is that person (a one-to-one call), so the
    /// call side is labelled with the name. With more than one name the labels stay as they are: a wrong name on a line
    /// is worse than none.
    public func namingTheCall() -> Meeting {
        let names = addressedNames
        guard names.count == 1, speakers.contains("On the call") else { return self }
        var m = self
        m.segments = segments.map { var s = $0; if s.speaker == "On the call" { s.speaker = names[0] }; return s }
        return m
    }
}

/// Who spoke when on the call side, and their names (docs/MEETINGS.md). Speaker separation gives "Person 1",
/// "Person 2"...; names come from how "You" addressed people: whoever speaks right after "Go ahead, Dana" is Dana,
/// decided by vote over the whole meeting, and only when the vote is clear.
public enum MeetingSpeakers {
    public struct Turn: Sendable { public let start: Double; public let end: Double; public let speaker: String
        public init(start: Double, end: Double, speaker: String) { self.start = start; self.end = end; self.speaker = speaker } }

    /// Labels the call side's segments with the separated speakers. A segment that two people share (each talking for
    /// at least a second) is cut at the change and each piece transcribed again, so one line is always one person.
    public static func label(_ segments: [MeetingSegment], callSide: String, turns: [Turn], callAudio: [Float], rate: Double = 16_000,
                             transcribe: ([Float]) async throws -> String) async throws -> [MeetingSegment] {
        guard !turns.isEmpty else { return segments }
        let order = turns.map(\.speaker).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        func person(_ id: String) -> String { "Person \((order.firstIndex(of: id) ?? 0) + 1)" }
        var out: [MeetingSegment] = []
        for seg in segments {
            guard seg.speaker == callSide else { out.append(seg); continue }
            // How long each speaker talks inside this segment.
            var pieces: [(start: Double, end: Double, speaker: String)] = []
            for t in turns where t.end > seg.start && t.start < seg.end {
                let a = max(t.start, seg.start), b = min(t.end, seg.end)
                if let last = pieces.last, last.speaker == t.speaker, a - last.end < 0.5 { pieces[pieces.count - 1].end = b }
                else { pieces.append((a, b, t.speaker)) }
            }
            let long = pieces.filter { $0.end - $0.start >= 2.0 }  // shorter pieces are usually the separator wavering, and re-cutting them breaks words
            if long.count >= 2, Set(long.map(\.speaker)).count >= 2 {
                for p in long {
                    let a = Int(p.start * rate), b = min(callAudio.count, Int((p.end + 0.15) * rate))
                    guard b - a > Int(rate * 0.3) else { continue }
                    let raw = try await transcribe(Array(callAudio[a..<b])).trimmingCharacters(in: .whitespacesAndNewlines)
                    let text = Numbers.apply(Tidy.apply(raw, mode: .correspondence))
                    if text.rangeOfCharacter(from: .alphanumerics) != nil {
                        out.append(MeetingSegment(speaker: person(p.speaker), start: p.start, end: p.end, text: text))
                    }
                }
            } else {
                var talk: [String: Double] = [:]
                for p in pieces { talk[p.speaker, default: 0] += p.end - p.start }
                var s = seg
                if let top = talk.max(by: { $0.value < $1.value }) { s.speaker = person(top.key) }
                out.append(s)
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Replaces "Person N" with a name when the meeting makes it clear: the person who speaks next after "You" says the
    /// name, at least once, and more often than any other person does after that name.
    public static func name(_ segments: [MeetingSegment]) -> [MeetingSegment] {
        let meeting = Meeting(id: "", started: Date(), duration: 0, segments: segments)
        let names = meeting.addressedNames
        guard !names.isEmpty else { return segments }
        var votes: [String: [String: Int]] = [:]   // name -> person -> times they answered
        for (i, seg) in segments.enumerated() where seg.speaker == "You" {
            for n in names where seg.text.contains(n) {
                if let next = segments[(i + 1)...].first(where: { $0.speaker.hasPrefix("Person ") }) {
                    votes[n, default: [:]][next.speaker, default: 0] += 1
                }
            }
        }
        // A person who only ever answered to one name is that person. The separator sometimes splits one voice in
        // two ("Person 1" and "Person 3" both answering to Dana); both then take the name. A person who answered to two
        // different names is left unnamed: a wrong name on a line is worse than none.
        var namesFor: [String: Set<String>] = [:]   // person -> names they answered to
        for (n, counts) in votes { for p in counts.keys { namesFor[p, default: []].insert(n) } }
        var map: [String: String] = [:]
        for (p, ns) in namesFor where ns.count == 1 { map[p] = ns.first! }
        // A call with one other voice and one name said: that voice is the name, wherever it was said.
        let people = Set(segments.map(\.speaker).filter { $0.hasPrefix("Person ") })
        if people.count == 1, names.count == 1, let only = people.first, map[only] == nil { map[only] = names[0] }
        return segments.map { var s = $0; if let n = map[s.speaker] { s.speaker = n }; return s }
    }
}
