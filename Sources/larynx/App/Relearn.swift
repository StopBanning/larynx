import AppKit
import Foundation
import LarynxCore

/// Self-learning from repeats: when you say something again in the same app within 90 seconds with a word changed,
/// Larynx learns the fix (see `Corrections`). Invented words go into the dictionary, new names into the vocabulary,
/// and real-word swaps ("send"/"sent") are only saved as suggestions for review. `learn: off` turns it off.
@MainActor
enum Relearn {
    struct Last { let text: String; let app: String?; let time: Date }
    static let window: TimeInterval = 90
    private(set) static var last: Last?
    /// The most recent lessons applied, for the menu's Undo.
    private(set) static var lastApplied: [Corrections.Lesson] = []

    static var suggestionsURL: URL { History.shared.root.appendingPathComponent("suggestions.json") }

    /// Call after each delivered dictation. Returns the lessons that were applied.
    @discardableResult
    static func check(_ text: String, app: String?, now: Date = Date()) -> [Corrections.Lesson] {
        defer { last = Last(text: text, app: app, time: now) }
        guard Settings.shared.string(.learn) != "off", let last, last.app == app,
              now.timeIntervalSince(last.time) <= window else { return [] }
        let lessons = Corrections.lessons(Corrections.changes(previous: last.text, current: text), words: MacWordList())
        return apply(lessons)
    }

    /// Forget the previous dictation (a password field, a snippet): it must not be compared with the next one.
    static func reset() { last = nil }

    /// Saves dictionary and vocabulary lessons; suggestions go to suggestions.json with a count.
    @discardableResult
    static func apply(_ lessons: [Corrections.Lesson]) -> [Corrections.Lesson] {
        var applied: [Corrections.Lesson] = []
        for lesson in lessons {
            switch lesson {
            case .dictionary(let heard, let meant):
                if Dictionary.load()[heard.lowercased()] != meant, (try? Dictionary.add(heard: heard, written: meant)) != nil {
                    applied.append(lesson)
                }
            case .vocabulary(let word):
                if Vocabulary.add(word) { applied.append(lesson) }
            case .suggestion(let heard, let meant):
                suggest(heard: heard, meant: meant)
            }
        }
        if !applied.isEmpty { lastApplied = applied }
        return applied
    }

    /// Takes back the last thing learned.
    static func undoLast() {
        for lesson in lastApplied {
            switch lesson {
            case .dictionary(let heard, _): _ = try? Dictionary.remove(heard: heard)
            case .vocabulary(let word): Vocabulary.remove(word)
            case .suggestion: break
            }
        }
        log("undid learning: " + describe(lastApplied))
        lastApplied = []
        Task { await reloadVocabulary() }
    }

    static func describe(_ lessons: [Corrections.Lesson]) -> String {
        lessons.compactMap { lesson -> String? in
            switch lesson {
            case .dictionary(let heard, let meant): return "\(heard) → \(meant)"
            case .vocabulary(let word): return lessons.contains { if case .dictionary(_, word) = $0 { return true }; return false } ? nil : word
            case .suggestion: return nil
            }
        }.joined(separator: ", ")
    }

    struct Suggestion: Codable { var heard: String; var meant: String; var count: Int; var last: Date }

    static func suggestions() -> [Suggestion] {
        (try? Data(contentsOf: suggestionsURL)).flatMap { try? JSONDecoder.iso.decode([Suggestion].self, from: $0) } ?? []
    }

    private static func suggest(heard: String, meant: String) {
        var all = suggestions()
        if let i = all.firstIndex(where: { $0.heard.lowercased() == heard.lowercased() && $0.meant == meant }) {
            all[i].count += 1; all[i].last = Date()
        } else {
            all.append(Suggestion(heard: heard, meant: meant, count: 1, last: Date()))
        }
        if let data = try? JSONEncoder.iso.encode(all) { try? data.write(to: suggestionsURL, options: .atomic) }
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }
}
extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
