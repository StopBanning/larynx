import Foundation
import LarynxText

/// A fix made in the History window (PLAN-v1 R5): "this came out wrong, here is what I said". The fix is saved as a
/// correction, the recording (when kept) joins the golden set with the fixed text, and a changed word that sounds
/// like the one typed becomes a lesson under the same rules as learning from a repeat (`Corrections.lessons`).
public enum HistoryFix {
    public struct Outcome: Equatable, Sendable {
        /// False when the text was empty or the same as what was typed: nothing was written.
        public var saved: Bool
        /// What can be learned from the change. The caller applies them (the app: `Relearn.apply`).
        public var lessons: [Corrections.Lesson]
        public var addedToGolden: Bool
    }

    /// Word swaps between what was typed and the fix. `Corrections.changes` needs three words, because a repeat
    /// that short could be anything; a fix is deliberate, so a one- or two-word dictation counts when the same
    /// number of words comes back with one changed.
    public static func changes(typed: String, fixed: String) -> [Corrections.Change] {
        let found = Corrections.changes(previous: typed, current: fixed)
        if !found.isEmpty { return found }
        let a = words(typed), b = words(fixed)
        guard a.count == b.count, (1...2).contains(a.count) else { return [] }
        let differing = zip(a, b).filter { $0.lowercased() != $1.lowercased() }
        guard differing.count == 1 else { return [] }
        return differing.map { Corrections.Change(heard: $0, meant: $1) }
    }

    /// Saves `fixed` as what dictation `row` should have said.
    public static func apply(_ row: History.Row, fixed: String, history: History, words: any WordList, now: Date = Date()) -> Outcome {
        let text = fixed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != row.text.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return Outcome(saved: false, lessons: [], addedToGolden: false)
        }
        history.recordCorrection(id: row.id, text: text, source: "fix", now: now)
        let golden = (try? Golden.add(row, text: text, source: "user", root: history.root, now: now)) != nil
        return Outcome(saved: true, lessons: Corrections.lessons(changes(typed: row.text, fixed: text), words: words), addedToGolden: golden)
    }

    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
    }
}
