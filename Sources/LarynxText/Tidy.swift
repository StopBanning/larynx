import Foundation

/// How much to polish, chosen from the app you are dictating into.
public enum CleanupMode: String, Codable, Sendable {
    /// AI chats, terminals, code editors: the model reading it doesn't care about polish. Light tidy, no added period.
    case ai
    /// Mail, Slack, Messages, Notes: text a person reads. Tidy, capitalize, end with punctuation.
    case correspondence
    /// Everything else: tidy and capitalize.
    case standard

    static let aiApps: Set<String> = [
        "com.anthropic.claudefordesktop", "com.openai.chat", "com.automatedworkflow.locust",
        "com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode", "dev.zed.Zed", "com.apple.dt.Xcode",
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
    ]
    static let correspondenceApps: Set<String> = [
        "com.apple.mail", "com.microsoft.Outlook", "com.tinyspeck.slackmacgap", "com.apple.MobileSMS",
        "net.whatsapp.WhatsApp", "ru.keepcoding.Telegram", "com.hnc.Discord", "com.apple.Notes",
        "com.microsoft.teams2", "notion.id", "com.apple.iWork.Pages", "com.microsoft.Word",
    ]

    public static func forApp(bundleID: String?) -> CleanupMode {
        guard let id = bundleID else { return .standard }
        if aiApps.contains(id) { return .ai }
        if correspondenceApps.contains(id) { return .correspondence }
        return .standard
    }


}

/// Rule-based tidy-up: instant, and it never rewrites a real word.
public enum Tidy {
    static let fillers = "(?:u+m+|u+h+m*|e+r+m+|h+m+)"
    /// Words people stutter on. Doubles of other words ("very very", "had had", "that that", "no no") are left alone.
    static let stutterWords = "the|a|an|to|i|we|you|it|is|and|of|in|on|for|my|our|can|so|but|or|if|he|she|they|this|at|with|be"
    static let joiners = "to|at|of|for|with|from|about|the|a|an|and|but|or|my|your|our|their"
    /// What may follow "on," / "in," when the comma is a leftover: a determiner, a number, or a capitalized name.
    static let clauseFollowers = "(?:(?i:the|a|an|my|your|our|their|his|her|its)\\b|\\d|(?i:one|two|three|four|five|six|seven|eight|nine|ten)\\b|(?!I\\b|I')[A-Z])"
    /// The subject of a new clause, after which "is," keeps its comma.
    static let clauseStarts = "(?i:i|i'm|i'll|i've|i'd|we|we're|we'll|you|you're|they|they're|he|she|it|it's|there|there's|that's|this)\\b"

    public static func apply(_ text: String, mode: CleanupMode) -> String {
        var s = text
        // 1. Leftover fillers, with the comma that came with them.
        s = s.replacingOccurrences(of: "(?i)(^|[\\s,])\(fillers)[,.]?(?=\\s|$)", with: "$1", options: .regularExpression)
        // 1b. "er", "ah", "eh" in the middle of a sentence are hesitations ("the total is, er, about"). Lowercase only,
        // so "the ER was packed" stays, and never at the start ("Ah, I see").
        s = s.replacingOccurrences(of: "(?<=[A-Za-z0-9])(?:,?\\s+(?:er|ah|eh)(?=[,.\\s]|$))+[,]?", with: "", options: .regularExpression)
        // 1c. "Aye, I, I": a stuttered "I" written as "Aye".
        s = s.replacingOccurrences(of: "(?i)(^|[.!?]\\s+)aye,?\\s+(?=i\\b)", with: "$1", options: .regularExpression)
        // 1d. A false start: an unfinished clause ending on a small word, then the same speaker starts again.
        // "I went to the, I drove to the store" -> "I drove to the store". "I went to the store, I bought milk" stays.
        s = s.replacingOccurrences(of: "(?i)(^|[.!?]\\s+)(i|we|you|he|she|they|it)\\s+(?:[\\w']+\\s+){0,3}(?:the|a|an|to|of|for|with|in|on|at|and|my|your|our|their),\\s+(?=\\2\\b)",
                                   with: "$1", options: .regularExpression)
        // 1e. A word cut off as the speaker starts the phrase again: "when we w when we want" -> "when we when we want"
        // (the repeat is removed next).
        s = cutOffRestarts(s)
        // 2. Words repeated as a false start: "we could, we could maybe" and "at the, the place".
        s = s.replacingOccurrences(of: "(?i)\\b(\\w+(?:\\s+\\w+){1,2}),\\s+\\1\\b", with: "$1", options: .regularExpression)
        s = repeatedPhrases(s)
        var previous = ""
        while previous != s {  // "I, I, I think" needs two passes
            previous = s
            s = s.replacingOccurrences(of: "(?i)\\b(\(stutterWords)),?\\s+\\1\\b", with: "$1", options: .regularExpression)
        }
        // 2b. "Tuesday, no Wednesday" / "at three. No, four": same kind of word on both sides, so keep the second.
        s = sameKindCorrections(s)
        // 2c. A question restarted with a different opener: "can you could you take a look" -> "could you take a look".
        s = s.replacingOccurrences(of: "(?i)\\b(?:\(questionOpeners))\\s+(?:you|i|we),?\\s+(?=(?:\(questionOpeners))\\s+(?:you|i|we)\\b)",
                                   with: "", options: .regularExpression)
        // 2d. "like" as filler between a form of "be" and an intensifier: "was like really big". "I like really spicy food" stays.
        s = s.replacingOccurrences(of: "(?i)\\b(was|is|are|were|it's|that's|they're|we're|you're|i'm)\\s+like,?\\s+(?=(?:really|so|very|super|totally|pretty|literally)\\b)",
                                   with: "$1 ", options: .regularExpression)
        // 2e. Trailing off: a sentence can't end on "and", "but" or "or" ("I'll call you later and, um.").
        let trailed = s.replacingOccurrences(of: "(?i)[\\s,.]+(?:and|but|or|an)[\\s,.]*$", with: "", options: .regularExpression)
        if trailed != s, !trailed.isEmpty { s = trailed + (mode == .ai ? "" : ".") }
        // 2f. Spoken code: case commands, file names, acronyms.
        s = CodeWords.apply(s)
        // 3. Commas stranded after small words where a filler used to be: "meet on, Thursday".
        // "on" and "in" also end phrasal verbs ("Hold on, I'll check", "Log in, then click save", "come in, whip up"),
        // so they lose the comma only before a determiner, a number or a capitalized name.
        s = s.replacingOccurrences(of: "(?i)\\b(\(joiners)),\\s+(?=\\w)", with: "$1 ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\b([Oo]n|[Ii]n),\\s+(?=\(clauseFollowers))", with: "$1 ", options: .regularExpression)
        // "The thing is, we need more time": a be-verb keeps its comma before a new clause's subject.
        s = s.replacingOccurrences(of: "\\b([Ii]s|[Ww]as|[Aa]re|[Ww]ere|[Bb]e),\\s+(?!\(clauseStarts))(?=\\w)", with: "$1 ",
                                   options: .regularExpression)
        // 3b. "if, Opus did it": a comma after "if" is a pause, not punctuation, unless it opens an aside ("if, say, it rains").
        s = s.replacingOccurrences(of: "(?i)\\bif,\\s+(?!(?:\(ifAsides))\\b)", with: "if ", options: .regularExpression)
        // 4. Spacing and doubled punctuation.
        s = s.replacingOccurrences(of: "\\s*,\\s*,+", with: ",", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+([,!?;:]|\\.(?![A-Za-z]))", with: "$1", options: .regularExpression)  // but not ".env"
        s = s.replacingOccurrences(of: "^[\\s,.;:]+", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // 4b. A dictation never ends on a comma or semicolon ("...the best in the biz,"): end it the way the mode ends
        // a trailed-off sentence (step 2e).
        if let last = s.last, last == "," || last == ";" {
            let cut = String(s.dropLast()).trimmingCharacters(in: .whitespaces)
            if !cut.isEmpty { s = cut + (mode == .ai ? "" : ".") }
        }
        guard !s.isEmpty else { return s }
        // 5. Capital letters at the start and after sentence ends.
        s = capitalizeSentences(s)
        // 6. Text for people ends like a sentence.
        if mode == .correspondence, let last = s.last, !".!?:)\"'".contains(last) { s += "." }
        return s
    }

    /// "we could we could push", "I want to I want to thank": a 2-3 word phrase said twice in a row. Counting
    /// ("one two one two"), numbers ("one to one to") and repeated single words ("wow wow wow wow") are left alone.
    /// Real one- and two-letter words: never treated as a cut-off word.
    static let shortWords: Set<String> = ["a", "i", "an", "as", "at", "be", "by", "do", "go", "he", "if", "in", "is", "it", "me", "my",
        "no", "of", "on", "or", "so", "to", "up", "us", "we", "am", "oh", "ok", "hi", "ha", "ah", "eh", "er", "um", "uh", "ma", "pa",
        "yo", "ya", "ye", "id", "ex"]

    /// Drops a lowercase one- or two-letter fragment when it is the start of a word said up to three words earlier and
    /// that same word comes right after it: the speaker stumbled and restarted ("when we w when we"). A capital letter
    /// is a label ("plan B because"), and real short words ("an answer is an answer") are never fragments.
    static func cutOffRestarts(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "\\b(([a-z]{1,2})[a-z']+)\\s+((?:[\\w']+\\s+){0,2})\\2\\s+(?=\\1\\b)",
                                                options: [.caseInsensitive]) else { return text }
        var s = text
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(m.range, in: s), let word = Range(m.range(at: 1), in: s),
                  let between = Range(m.range(at: 3), in: s) else { continue }
            // The fragment is the last token of the match.
            guard let fragment = s[whole].split(whereSeparator: \.isWhitespace).last.map(String.init) else { continue }
            if fragment != fragment.lowercased() || shortWords.contains(fragment) { continue }
            // "them th them": nothing in between, so the word itself was said twice; keep the one that follows.
            s.replaceSubrange(whole, with: s[between].isEmpty ? "" : s[word] + " " + s[between])
        }
        return s
    }

    static func repeatedPhrases(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "(?i)\\b([\\w']+(?:\\s+[\\w']+){1,2})\\s+\\1\\b") else { return text }
        let numberWords: Set<String> = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "zero"]
        var s = text
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(m.range, in: s), let phrase = Range(m.range(at: 1), in: s) else { continue }
            let words = s[phrase].lowercased().split(whereSeparator: \.isWhitespace)
            // Numbers ("one to one to the app" is "one-to-one") and one word said over and over ("wow wow wow wow")
            // are meant, not stumbles.
            if words.contains(where: { numberWords.contains(String($0)) || $0.allSatisfy(\.isNumber) }) { continue }
            if Set(words).count == 1 { continue }
            s.replaceSubrange(whole, with: String(s[phrase]))
        }
        return s
    }

    static let questionOpeners = "can|could|will|would|should|do|did|shall"
    /// Asides that keep their commas after "if": "if, say, it rains", "if, you know, you want".
    static let ifAsides = "say|you know|honestly|though|i mean|of course|for example|for instance|like|basically|frankly|"
        + "perhaps|maybe|by chance|god forbid|heaven forbid|anything|anyway|in fact|for some reason|somehow|necessary|possible|needed|not|so"

    static let correctionKinds = [
        "(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|today|tomorrow|tonight)",
        "(?:january|february|march|april|may|june|july|august|september|october|november|december)",
        "(?:\\d+(?::\\d\\d)?(?:\\s?[ap]\\.?m\\.?)?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|"
            + "fifteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred)",
    ]

    /// Replaces "<X>, no <Y>" with "<Y>" when X and Y are the same kind (weekday, month, number or time).
    /// Exact and instant, and the shape Apple's model most often gets backwards.
    static func sameKindCorrections(_ text: String) -> String {
        var s = text
        for kind in correctionKinds {
            s = s.replacingOccurrences(of: "(?i)\\b\(kind)[,.]\\s+no,?\\s+(\(kind))\\b", with: "$1", options: .regularExpression)
        }
        return s
    }

    /// Capitalizes the first letter and the first letter after ". ", "! " or "? ", but not after "..." or inside "example.com".
    static func capitalizeSentences(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        var capNext = true
        for (i, ch) in chars.enumerated() {
            if capNext, ch.isLetter {
                capNext = false
                // Leave code alone: userId, user_id, main.swift, iOS keep their case.
                let word = chars[i...].prefix { !$0.isWhitespace }
                let codeLike = word.contains("_") || word.dropFirst().contains(where: \.isUppercase)
                    || word.dropLast().contains(".") || ch.isUppercase
                if !codeLike { out += ch.uppercased(); continue }
            }
            if capNext, !ch.isWhitespace { capNext = false }
            if ".!?".contains(ch) {
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                let ellipsis = ch == "." && ((i > 0 && chars[i - 1] == ".") || next == ".")
                capNext = next.isWhitespace && !ellipsis
            }
            out.append(ch)
        }
        return out
    }
}

