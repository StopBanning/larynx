import Foundation
import NaturalLanguage

/// Homophones settled by what's on screen (PLAN-v1 C3, generalized): a noun in the dictation that sounds exactly
/// like a name on screen takes the screen's spelling ("ask the clod" + "Claude" on screen -> "ask the Claude";
/// "pin it to the doc" + "Dock" -> "pin it to the Dock"). Audio can't tell these apart, only context can. A word that
/// isn't a noun where it stands ("make it so", "the real reason") never changes. Runs in shadow until proven.
public enum ContextWords {
    public static func proposal(_ text: String, screenTerms: [String]) -> String? {
        let names = screenTerms.filter { $0.first?.isUppercase == true && $0.count >= 3 }
        guard !names.isEmpty, !text.isEmpty else { return nil }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var swaps: [(Range<String.Index>, String)] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitPunctuation, .omitWhitespace]) { tag, range in
            guard tag == .noun else { return true }
            let word = String(text[range])
            guard word.first?.isLowercase == true, word.count >= 3 else { return true }
            if let name = names.first(where: { $0.lowercased() != word.lowercased() && phoneticKey(word) == phoneticKey($0) && sameStart(word, $0) }) {
                swaps.append((range, name))
            }
            return true
        }
        guard !swaps.isEmpty else { return nil }
        var out = text
        for (range, name) in swaps.reversed() { out.replaceSubrange(range, with: name) }
        return out
    }

    /// How a word sounds, roughly: consonants only, with spelling variants folded ("Dock" and "doc" -> "dk",
    /// "Claude" and "clod" -> "kld", "phone" and "fone" -> "fn").
    public static func phoneticKey(_ word: String) -> String {
        var s = word.lowercased().filter(\.isLetter)
        for (a, b) in [("ph", "f"), ("ck", "k"), ("qu", "kw"), ("wh", "w"), ("x", "ks")] { s = s.replacingOccurrences(of: a, with: b) }
        let chars = Array(s)
        var out: [Character] = []
        for (i, c) in chars.enumerated() {
            var k = c
            if c == "c" { k = i + 1 < chars.count && "eiy".contains(chars[i + 1]) ? "s" : "k" }
            if "aeiouy".contains(k) { continue }
            if out.last != k { out.append(k) }
        }
        return String(out)
    }

    /// Same first sound: "clod"/"Claude" (c/k), "doc"/"Dock". Keeps "rust" from matching "Russ".
    static func sameStart(_ a: String, _ b: String) -> Bool {
        let fold: (Character) -> Character = { c in "ck".contains(c) ? "k" : c }
        guard let x = a.lowercased().first, let y = b.lowercased().first else { return false }
        return fold(x) == fold(y)
    }
}
