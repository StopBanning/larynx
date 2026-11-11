import Foundation

/// Deterministic safety checks for a candidate rewrite; never calls a language model.
public enum RewriteGuard {
    static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted).filter { !$0.isEmpty }
    }

    /// Returns why the edit is unsafe, or nil. A safe edit only deletes words or turns number words into digits.
    /// Corrections legitimately delete the wrong half ("blue one, scratch that, red one"), so they may drop more.
    public static func guardProblem(original: String, edited: String, correction: Bool = false) -> String? {
        let before = words(original), after = words(edited)
        if after.isEmpty { return "empty" }
        let floor = correction ? before.count / 4 : before.count / 2
        if after.count < max(2, floor) { return "dropped too much" }
        if after.count > before.count + 2 { return "added words" }
        let known = Set(before)
        let novel = after.filter { !known.contains($0) && !$0.allSatisfy(\.isNumber) && Double($0) == nil }
        if !novel.isEmpty { return "new words \(novel)" }
        if correction, let kept = correctedWord(in: original), !after.contains(kept) {
            return "dropped the correction \"\(kept)\""
        }
        return nil
    }

    static let numberWords: Set<String> = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand"]

    /// The first real word said after a correction cue ("Tuesday, no Wednesday" -> "wednesday"). A rewrite that drops it
    /// kept the wrong half. Number words are skipped because they legitimately turn into digits.
    static func correctedWord(in text: String) -> String? {
        // "no wait" / "wait no" come first so ", no wait, three" never captures "wait".
        let pattern = #"(?i)(?:(?:[,.]\s+)?(?:no,? wait|wait,? no)|[,.]\s+no|sorry|i mean|actually|make that|or rather|scratch that),?\s+(?:the\s+|a\s+|an\s+)?([a-z']+)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        let word = text[r].lowercased()
        return numberWords.contains(word) ? nil : word
    }
}
