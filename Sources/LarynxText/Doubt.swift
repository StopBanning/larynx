import Foundation

/// Words the speech model probably misheard, from its own confidence (PLAN-v1 B4). Calibrated on the author's golden
/// set (docs/BENCHMARKS.md): under 0.4 caught "Robus" (0.34) and "Presume" (0.36) with 1 false alarm in 842 right
/// words. A word no dictionary knows is doubtful a little earlier (under 0.8), unless it is capitalized (a name).
public enum Doubt {
    public static let lowConfidence: Float = 0.4
    public static let unknownWordConfidence: Float = 0.8
    static let fillers: Set<String> = ["uh", "um", "er", "ah", "eh", "erm", "hmm", "mm"]

    /// The doubtful words in `words` (model output with confidences) that still appear in `finalText`: a word the
    /// dictionary or vocabulary already replaced is no longer in doubt.
    public static func words(_ words: [(word: String, confidence: Float)], finalText: String, isKnown: (String) -> Bool) -> [String] {
        let typed = Set(finalText.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init))
        var out: [String] = []
        for (raw, confidence) in words {
            let word = raw.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'")))
            let key = word.lowercased()
            guard !word.isEmpty, !fillers.contains(key), typed.contains(key), !out.contains(word) else { continue }
            let unknown = word.first.map { !$0.isUppercase } ?? false && !isKnown(key)
            if confidence < lowConfidence || (unknown && confidence < unknownWordConfidence) { out.append(word) }
        }
        return out
    }
}
