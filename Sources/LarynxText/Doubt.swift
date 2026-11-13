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

    /// Doubted words that are only the start of a word, said as the speaker changed course: "I was tra trying to",
    /// "it's fine, bu, honestly". All must hold: the model doubted it; it is lowercase, letters only, at most
    /// seven of them; no dictionary or vocabulary knows it; a real word starts with it; and it appears once (a sound
    /// said over and over, "dum dum dum", is meant). Read against 541 re-transcribed real dictations: 4 found, all
    /// cut-offs, nothing else (one of them, an abbreviation macOS knows, is left in by the app).
    public static func cutOffs(_ doubtful: [String], in text: String, isKnown: (String) -> Bool, startsAWord: (String) -> Bool) -> [String] {
        let tokens = text.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        return doubtful.filter { word in
            guard (1...7).contains(word.count), word.allSatisfy({ $0.isLetter && $0.isLowercase }), !isKnown(word),
                  startsAWord(word) else { return false }
            return tokens.filter { $0.lowercased() == word }.count == 1 && tokens.contains(word)
        }
    }

    /// `text` without each of `words` (whole words, once each), with the space and any comma it leaves tidied.
    public static func removing(_ words: [String], from text: String) -> String {
        var s = text
        for word in words {
            let pattern = "\\s*(?<![\\w'])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\w'])"
            if let r = s.range(of: pattern, options: .regularExpression) { s.replaceSubrange(r, with: "") }
        }
        s = s.replacingOccurrences(of: "\\s+([,.!?;:])", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: ",\\s*,", with: ",", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }
}
