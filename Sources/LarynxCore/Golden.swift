import Foundation

/// The golden set: recordings of your own dictations with what you really said, used as the benchmark that matters
/// most (`python3 bench/run.py --sets golden`). Lives in `golden/` next to your history, never in git, never uploaded.
/// Audio is copied in, so a clip outlives the `keepAudio` window.
public struct GoldenClip: Codable, Equatable, Sendable {
    public var id: String
    /// Absolute path of the copied recording (the benchmark reads it directly).
    public var audio: String
    /// What was said, as it should be typed.
    public var text: String
    /// Names in the reference (capitalized words not at a sentence start), for the names score.
    public var names: [String]
    /// Where the reference came from: "edit", "repeat", "user" (typed in), or "agent" (checked by an assistant
    /// against the conversation and the four speech models).
    public var source: String
    public var mode: String
    public var engine: String
    public var raw: String
    public var audioSeconds: Double
    public var added: Date
}

public enum Golden {
    public static func directory(root: URL = History.shared.root) -> URL { root.appendingPathComponent("golden", isDirectory: true) }
    public static func manifest(root: URL = History.shared.root) -> URL { directory(root: root).appendingPathComponent("manifest.jsonl") }

    public static func load(root: URL = History.shared.root) -> [GoldenClip] {
        guard let text = try? String(contentsOf: manifest(root: root), encoding: .utf8) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(GoldenClip.self, from: Data($0.utf8)) }
    }

    static func save(_ clips: [GoldenClip], root: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let lines = try clips.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        try History.makePrivateDirectory(directory(root: root))
        try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: manifest(root: root), atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest(root: root).path)
    }

    public enum GoldenError: Error, CustomStringConvertible {
        case noAudio(String), emptyText
        public var description: String {
            switch self {
            case .noAudio(let id): return "dictation \(id) has no kept recording (keepAudio in settings.json)"
            case .emptyText: return "the reference text is empty"
            }
        }
    }

    /// Adds (or replaces) a clip: copies the dictation's recording and stores `text` as what was said.
    @discardableResult
    public static func add(_ row: History.Row, text: String, source: String, root: URL = History.shared.root, now: Date = Date()) throws -> GoldenClip {
        let reference = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else { throw GoldenError.emptyText }
        guard let path = row.audioPath, FileManager.default.fileExists(atPath: path) else { throw GoldenError.noAudio(row.id) }
        try History.makePrivateDirectory(directory(root: root))
        let target = directory(root: root).appendingPathComponent(row.id + "." + URL(fileURLWithPath: path).pathExtension)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: target)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let clip = GoldenClip(id: row.id, audio: target.path, text: reference, names: names(in: reference), source: source,
                              mode: row.mode, engine: row.engine, raw: row.raw, audioSeconds: row.audioSeconds, added: now)
        var clips = load(root: root).filter { $0.id != row.id }
        clips.append(clip)
        try save(clips, root: root)
        return clip
    }

    /// Removes a clip and its recording.
    @discardableResult
    public static func remove(id: String, root: URL = History.shared.root) throws -> Bool {
        let clips = load(root: root)
        guard let clip = clips.first(where: { $0.id == id }) else { return false }
        try? FileManager.default.removeItem(atPath: clip.audio)
        try save(clips.filter { $0.id != id }, root: root)
        return true
    }

    // MARK: Random set (R4)

    /// A clip picked at random for labelling: what each speech model heard, and the label if they all agree.
    /// Kept in `golden/pending.jsonl` (private, never in git) until `larynx golden label` accepts or corrects it.
    public struct Pending: Codable, Equatable, Sendable {
        public var id: String
        public var audio: String
        public var audioSeconds: Double
        public var band: String
        /// Engine name -> what it heard (filled by `bench/prelabel.py`).
        public var heard: [String: String] = [:]
        /// The proposed label when every engine heard the same words; nil when they differ (needs you).
        public var agreed: String? = nil
        public init(id: String, audio: String, audioSeconds: Double, band: String) {
            self.id = id; self.audio = audio; self.audioSeconds = audioSeconds; self.band = band
        }
    }

    public static func pendingFile(root: URL = History.shared.root) -> URL { directory(root: root).appendingPathComponent("pending.jsonl") }

    public static func loadPending(root: URL = History.shared.root) -> [Pending] {
        guard let text = try? String(contentsOf: pendingFile(root: root), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(Pending.self, from: Data($0.utf8)) }
    }

    public static func savePending(_ items: [Pending], root: URL = History.shared.root) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let lines = try items.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        try History.makePrivateDirectory(directory(root: root))
        try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: pendingFile(root: root), atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pendingFile(root: root).path)
    }

    /// Length band, so the random set isn't all one-liners: under 5 s, 5-15 s, over 15 s.
    public static func band(_ seconds: Double) -> String { seconds < 5 ? "short" : seconds <= 15 ? "medium" : "long" }

    /// Picks `n` dictations at random, a third from each length band (topped up from the others when a band runs
    /// short). Skips clips without a kept recording, clips already in the set or waiting, private apps and clips
    /// under half a second. The same seed gives the same pick.
    public static func sample(_ rows: [History.Row], n: Int, skip: Set<String>, privateApps: Set<String>, seed: UInt64,
                              hasAudio: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [History.Row] {
        var rng = SplitMix64(seed: seed)
        let usable = rows.filter { r in
            guard let path = r.audioPath, hasAudio(path), !skip.contains(r.id), r.audioSeconds >= 0.5 else { return false }
            return !(r.app.map(privateApps.contains) ?? false)
        }
        var pools = ["short", "medium", "long"].map { b in usable.filter { band($0.audioSeconds) == b }.shuffled(using: &rng) }
        var picked: [History.Row] = []
        // Round-robin over the bands: equal shares while every band has clips, the others fill in after.
        while picked.count < n, pools.contains(where: { !$0.isEmpty }) {
            for i in pools.indices where picked.count < n && !pools[i].isEmpty { picked.append(pools[i].removeFirst()) }
        }
        return picked
    }

    /// Words only: lower case, no punctuation, hyphens as spaces ("Larynx, re-run." -> "larynx re run").
    public static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).joined(separator: " ")
    }

    /// The proposed label when at least two engines heard the same words: the typed text if it says those words
    /// (it carries your punctuation and cleanup), otherwise the first engine's. Nil when any engine differs or is empty.
    public static func agreed(heard: [String: String], typed: String) -> String? {
        let texts = heard.keys.sorted().compactMap { heard[$0] }
        guard texts.count >= 2, let first = texts.first else { return nil }
        let words = normalized(first)
        guard !words.isEmpty, texts.allSatisfy({ normalized($0) == words }) else { return nil }
        return normalized(typed) == words ? typed : first
    }

    /// Capitalized words that aren't at the start of a sentence and aren't "I": "Ask Priya about Opus" -> [Priya, Opus].
    public static func names(in text: String) -> [String] {
        var out: [String] = []
        var sentenceStart = true
        for raw in text.split(whereSeparator: \.isWhitespace) {
            let word = raw.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'")))
            defer { sentenceStart = raw.last.map { ".!?".contains($0) } ?? false }
            guard let first = word.first, first.isUppercase, !sentenceStart else { continue }
            if word == "I" || word.hasPrefix("I'") || word.allSatisfy({ $0.isUppercase }) && word.count == 1 { continue }
            if !out.contains(word) { out.append(word) }
        }
        return out
    }

    /// "Same words, up to three changed": the second dictation corrects the first. Rephrasings don't count.
    public static func isWordFix(_ first: String, _ second: String) -> Bool {
        let a = words(first), b = words(second)
        guard a != b, !a.isEmpty, abs(a.count - b.count) <= 1, a.count >= 3 else { return false }
        let common = lcs(a, b)
        let changed = max(a.count, b.count) - common
        return changed >= 1 && changed <= 3 && Double(common) / Double(max(a.count, b.count)) >= 0.7
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }

    static func lcs(_ a: [String], _ b: [String]) -> Int {
        var row = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var prev = 0
            for (j, y) in b.enumerated() {
                let keep = row[j + 1]
                row[j + 1] = x == y ? prev + 1 : max(row[j + 1], row[j])
                prev = keep
            }
        }
        return row[b.count]
    }
}

/// Small seeded generator so a sample can be repeated (`--seed`).
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
