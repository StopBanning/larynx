import Foundation

/// Names and terms worth listening for, taken from text on screen (PLAN-v1 C2, master 2.2): capitalized words that
/// aren't at the start of a sentence ("ask Claude", "the Dock"), identifiers (camelCase, snake_case, file.names) and
/// words no dictionary knows. Pass the text nearest the cursor first: the first `limit` distinct terms win.
public enum ContextTerms {
    static let skip: Set<String> = ["I", "I'm", "I'll", "I've", "I'd", "OK", "Okay", "Yes", "No", "The", "A", "An"]

    public static func extract(_ texts: [String], isEnglish: (String) -> Bool, limit: Int = 40) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        // Each line starts a sentence: one-word interface labels ("Pinned", "Settings") are not names.
        for line in texts.flatMap({ $0.split(whereSeparator: \.isNewline) }) {
            var sentenceStart = true
            for raw in line.split(whereSeparator: { $0.isWhitespace }) {
                let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’()[]{}<>,;:!?*`"))
                defer { sentenceStart = raw.last.map { ".!?\n".contains($0) } ?? false || raw.hasSuffix(":") }
                guard token.count >= 3, token.count <= 40, token.first?.isLetter == true else { continue }
                let word = token.hasSuffix(".") && !token.dropLast().contains(".") ? String(token.dropLast()) : token
                let lower = word.lowercased()
                guard !skip.contains(word), !seen.contains(lower) else { continue }
                let identifier = word.contains("_") || (word.dropFirst().contains(where: \.isUppercase) && word.contains(where: \.isLowercase))
                    || (word.contains(".") && word.split(separator: ".").count == 2 && word.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." })
                let name = word.first!.isUppercase && !sentenceStart && word.dropFirst().allSatisfy { $0.isLowercase || $0 == "'" }
                let unknown = word.allSatisfy(\.isLetter) && word.first!.isLowercase && !isEnglish(lower)
                guard identifier || name || unknown else { continue }
                seen.insert(lower)
                out.append(word)
                if out.count >= limit { return out }
            }
        }
        return out
    }
}
