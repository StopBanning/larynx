import Foundation

/// Fits a dictation to the text already in the field, just before it is pasted (PLAN-v1 C4, master 2.3): a space
/// after the previous text when one is missing ("time." + "Are we" -> "time. Are we"), and a lowercase first word
/// when the dictation lands mid-sentence ("Hey Sam," + "Can you" -> "Hey Sam, can you"). Unreadable fields, empty
/// fields, a new line and a selection being replaced all leave the text exactly as it is.
public enum Fit {
    /// - Parameters:
    ///   - before: the field's text before the cursor, or nil when it can't be read.
    ///   - replacingSelection: text is selected, so the paste replaces it.
    ///   - keepsCapital: names and terms that keep their capital mid-sentence (vocabulary, "Opus", "Fable").
    ///   - isEnglish: whether a lowercase word is an ordinary English word.
    public static func adjust(_ text: String, before: String?, replacingSelection: Bool = false,
                              keepsCapital: (String) -> Bool = { _ in false }, isEnglish: (String) -> Bool) -> String {
        guard let before, !before.isEmpty, !replacingSelection, let last = before.last, !text.isEmpty else { return text }
        if last.isNewline { return text }
        var out = text
        let previous = before.trimmingCharacters(in: .whitespaces)
        // After an opening bracket or quote a capital is often meant ("He said “Are we…"), so leave it.
        let sentenceEnded = previous.last.map { ".!?([{\"'“‘".contains($0) } ?? true
        if !sentenceEnded, let word = firstWord(of: out), shouldLowercase(word, keepsCapital: keepsCapital, isEnglish: isEnglish) {
            out = word.lowercased() + out.dropFirst(word.count)
        }
        // A space unless the field already ends in one, or in something that opens: a bracket, quote, slash, @ or #.
        let opens = "([{\"'“‘/@#-"
        if !last.isWhitespace, !opens.contains(last), let first = out.first, !",.;:!?)]}".contains(first) {
            out = " " + out
        }
        return out
    }

    static func firstWord(of text: String) -> String? {
        let word = text.prefix { $0.isLetter || $0 == "'" || $0 == "’" }
        return word.isEmpty ? nil : String(word)
    }

    /// Only a capital that is there because Larynx started a sentence: an ordinary English word written "Can",
    /// not "I", "I'm", an acronym ("API"), camelCase, or a name.
    static func shouldLowercase(_ word: String, keepsCapital: (String) -> Bool, isEnglish: (String) -> Bool) -> Bool {
        guard let first = word.first, first.isUppercase else { return false }
        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") { return false }
        if word.dropFirst().contains(where: \.isUppercase) { return false }
        if keepsCapital(word) { return false }
        return isEnglish(word.lowercased())
    }
}
