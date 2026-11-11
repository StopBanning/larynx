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
