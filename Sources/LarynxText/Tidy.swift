import Foundation

/// How much to polish, chosen from the app you are dictating into.
/// How the text should read (PLAN-v1 section P). `CleanupMode` is where it is going (an AI chat, a message, an
/// email); the style is the register. Casual is everything Larynx did before; professional also removes what you'd
/// leave out when writing to a client: discourse fillers, "dude", swearing used for emphasis, spoken forms like
/// "gonna", and turns spoken lists into real ones.
public enum Style: String, Codable, Sendable, CaseIterable {
    case casual, professional
}

public enum CleanupMode: String, Codable, Sendable {
    /// AI chats, terminals, code editors: the model reading it doesn't care about polish. Light tidy, no added period.
    case ai
    /// Mail, Slack, Messages, Notes: text a person reads. Tidy, capitalize, end with punctuation.
    case correspondence
    /// Everything else: tidy and capitalize.
    case standard
    /// Mail apps: like correspondence, plus email layout (greeting and sign-off on their own lines).
    case email

    /// Text a person reads: ends like a sentence.
    public var isForPeople: Bool { self == .correspondence || self == .email }

    static let aiApps: Set<String> = [
        "com.anthropic.claudefordesktop", "com.openai.chat", "com.automatedworkflow.locust",
        "com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode", "dev.zed.Zed", "com.apple.dt.Xcode",
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
    ]
    static let emailApps: Set<String> = ["com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac",
                                         "com.superhuman.electron", "it.bloop.airmail2"]
    static let correspondenceApps: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.apple.MobileSMS",
        "net.whatsapp.WhatsApp", "ru.keepcoding.Telegram", "com.hnc.Discord", "com.apple.Notes",
        "com.microsoft.teams2", "notion.id", "com.apple.iWork.Pages", "com.microsoft.Word",
    ]

    public static func forApp(bundleID: String?) -> CleanupMode {
        guard let id = bundleID else { return .standard }
        if aiApps.contains(id) { return .ai }
        if emailApps.contains(id) { return .email }
        if correspondenceApps.contains(id) { return .correspondence }
        return .standard
    }


}

/// Rule-based tidy-up: instant, and it never rewrites a real word.
public enum Tidy {
    static let fillers = "(?:u+m+|u+h+m*|e+r+m+|h+m+)"
    /// Words people stutter on. Doubles of other words ("very very", "had had", "that that", "no no") are left alone.
    static let stutterWords = "the|a|an|to|i|we|you|it|is|and|of|in|on|for|my|our|can|so|but|or|if|he|she|they|this|at|with|be|"
        + "some|which|until|would|are|as|just|keep|i'm|i'll|i've|it's|don't|let's|we're|you're|that's"
    // MARK: Email layout

    static let greetings = "Hi|Hey|Hello|Dear|Good morning|Good afternoon|Good evening|Morning|Afternoon"
    static let signOffs = "Thanks|Thank you|Thanks so much|Many thanks|Best|Best regards|Kind regards|Regards|Cheers|Talk soon|Sincerely|All the best|Warmly"

    /// Mail layout: "Hi Sam, thanks for…" → "Hi Sam,\n\nThanks for…"; "…tomorrow. Thanks, Colin." →
    /// "…tomorrow.\n\nThanks,\nColin". A greeting needs more text after it; a sign-off needs a name after it, so
    /// "Thanks for the help." stays a sentence.
    static func emailLayout(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "^((?:\(greetings))(?:\\s+[A-Z][\\w'-]*){0,3})[,.!]?\\s+(?=\\S)", with: "$1,\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?<=[.!?])\\s+((?:\(signOffs))(?: [a-z]+)?)[,.!]?\\s+([A-Z][\\w'-]*(?:\\s+[A-Z][\\w'-]*)?)[.!]?$",
                                   with: "\n\n$1,\n$2", options: .regularExpression)
        return s
    }

    /// Ends in a sign-off and a name on its own line: no full stop after the name.
    static func emailSignedOff(_ text: String) -> Bool {
        text.range(of: "\n(?:\(signOffs))(?: [a-z]+)?,\n[^\n]+$", options: .regularExpression) != nil
    }

    // MARK: Shadow rules

    /// Experimental rules that run on every dictation but change nothing: each proposal is recorded in history as a
    /// `shadow:<name>` step, and `larynx mine --shadow` lists them. A rule moves into `apply` once its proposals on
    /// real dictations have been read and are right (PLAN-v1 B1: every risky rule goes through here first).
    public static let shadowRules: [(name: String, apply: (String) -> String)] = [
        ("lone-letter", loneLetterRestarts),
        ("spoken-list", spokenList),
        ("counted-list", countedList),
        ("spoken-punctuation", spokenPunctuation),
    ]

    /// "Send it tomorrow question mark" -> "Send it tomorrow?": a punctuation name said right after a word becomes
    /// the mark. Not after a determiner or number ("the period of time", "a comma", "two colons"), and only where the
    /// name ends the phrase (end, or another mark or word follows it).
    static func spokenPunctuation(_ text: String) -> String {
        let marks: [(String, String)] = [("question mark", "?"), ("exclamation mark", "!"), ("exclamation point", "!"),
                                         ("full stop", "."), ("period", "."), ("comma", ","), ("semicolon", ";"), ("colon", ":")]
        var s = text
        for (name, mark) in marks {
            let pattern = "(?i)(?<![\\w'])(?!(?:the|a|an|this|that|one|two|three|every|each|no)\\s)([A-Za-z0-9']+)[,.]?\\s+" + name + "[.,!?]?(?=\\s|$)"
            s = s.replacingOccurrences(of: pattern, with: "$1" + mark, options: .regularExpression)
        }
        return s
    }

    /// "There are three things I want from you. I want you to provide the report, get it back, ship it off." An
    /// announced count followed by exactly that many comma-separated items (each two words or more) becomes a
    /// numbered list. A lead-in shared by the items ("I want you to") stays above the list.
    static func countedList(_ text: String) -> String {
        let counts = ["two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6]
        guard let m = text.range(of: "(?i)\\b(two|three|four|five|six|[2-6])\\s+(?:\\w+\\s+)?(things|steps|items|points|tasks|questions|ideas|options)\\b[^.:!?]*[.:]",
                                 options: .regularExpression),
              let countWord = text[m].split(separator: " ").first,
              let n = counts[countWord.lowercased()] else { return text }
        let intro = String(text[..<m.upperBound])
        var body = String(text[m.upperBound...]).trimmingCharacters(in: .whitespaces)
        // The items run to the end of the next sentence.
        var after = ""
        if let end = body.range(of: "[.!?](\\s|$)", options: .regularExpression) {
            after = String(body[end.upperBound...]); body = String(body[..<end.lowerBound])
        }
        var lead = ""
        if let l = body.range(of: "^(?i)(?:I want you to|I need you to|you need to|we need to|we should|please|you should)\\s+", options: .regularExpression) {
            lead = String(body[l]).trimmingCharacters(in: .whitespaces); body = String(body[l.upperBound...])
        }
        let items = body.replacingOccurrences(of: ",?\\s+and\\s+(?=[^,]*$)", with: ", ", options: .regularExpression)
            .components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }
        guard items.count == n, items.allSatisfy({ $0.split(separator: " ").count >= 2 }) else { return text }
        let list = items.enumerated().map { "\($0.offset + 1). " + $0.element.prefix(1).uppercased() + $0.element.dropFirst() }
        var out = intro.trimmingCharacters(in: .whitespaces)
        if !lead.isEmpty { out += " " + lead + ":" }
        out += "\n" + list.joined(separator: "\n")
        let rest = after.trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? out : out + "\n\n" + rest
    }

    /// "Number one, flights. Number two, hotels." / "First, flights, second, hotels" → a numbered list, one item per
    /// line. Needs at least two items in order starting at one; otherwise nothing changes.
    static func spokenList(_ text: String) -> String {
        let ordinals = ["one|first", "two|second", "three|third", "four|fourth", "five|fifth", "six|sixth"]
        var items: [String] = []
        var rest = Substring(text)
        var lead = ""
        for (n, words) in ordinals.enumerated() {
            guard let r = rest.range(of: "(?i)(?:^|(?<=[.,;:!?])\\s+|\\s+)(?:number\\s+)?(?:\(words))[,.:]\\s+", options: .regularExpression) else { break }
            if n == 0 { lead = String(rest[..<r.lowerBound]) } else { items.append(String(rest[..<r.lowerBound])) }
            rest = rest[r.upperBound...]
        }
        guard !items.isEmpty else { return text }
        items.append(String(rest))
        let clean = items.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ,;.")) }
        guard clean.allSatisfy({ !$0.isEmpty }) else { return text }
        let list = clean.enumerated().map { "\($0.offset + 1). " + $0.element.prefix(1).uppercased() + $0.element.dropFirst() }.joined(separator: "\n")
        let intro = lead.trimmingCharacters(in: .whitespaces)
        return intro.isEmpty ? list : intro + "\n" + list
    }

    /// A lone lowercase letter that starts a word said a little later: "we can b maybe borrow it"
    /// drops the "f". Not when it labels something ("plan b", "vitamin d", "the letter s") or the word follows at once
    /// ("the b branch").
    static func loneLetterRestarts(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "(?<![\\w'.-])([b-hj-z])\\s+((?:[\\w']+\\s+){1,2})(?=\\1[a-z])") else { return text }
        let labels: Set<String> = ["plan", "vitamin", "letter", "option", "grade", "type", "class", "section", "part", "step",
                                   "row", "column", "size", "model", "version", "level", "tier", "group", "team", "line", "the", "a",
                                   "press", "hit", "tap", "key", "type", "and", "or"]
        var s = text
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let letter = Range(m.range(at: 1), in: s) else { continue }
            let before = s[..<letter.lowerBound].split(whereSeparator: \.isWhitespace).last.map { $0.lowercased() } ?? ""
            if labels.contains(before) { continue }
            guard let whole = Range(NSRange(location: m.range.location, length: m.range(at: 1).length + 1), in: s) else { continue }
            s.removeSubrange(whole)
        }
        return s
    }

    /// Verbs a speaker restarts a sentence with ("I went to the, I drove"); "I phone", "I beam" are not restarts.
    static let restartVerbs = "[a-z]+ed|drove|went|was|think|thought|want|need|have|had|got|get|said|say|mean|guess|told|saw|see|did|do|don't|didn't|put|took|take|made|make|can|could|will|would|just|really|also|bought|came|come|left|ran|found|know|knew|love|like|wanna|gotta|gonna"
    /// Small words a speaker goes back to when correcting the next word ("from your uh from our", "the cat um the dog").
    static let restartWords = "from|to|in|on|at|for|with|of|about|into|the|a|an|my|your|our|their|his|her|this|that"
    static let joiners = "to|at|of|for|with|from|about|the|a|an|and|but|or|my|your|our|their"
    /// What may follow "on," / "in," when the comma is a leftover: a determiner, a number, or a capitalized name.
    static let clauseFollowers = "(?:(?i:the|a|an|my|your|our|their|his|her|its)\\b|\\d|(?i:one|two|three|four|five|six|seven|eight|nine|ten)\\b|(?!I\\b|I')[A-Z])"
    /// The subject of a new clause, after which "is," keeps its comma.
    static let clauseStarts = "(?i:i|i'm|i'll|i've|i'd|we|we're|we'll|you|you're|they|they're|he|she|it|it's|there|there's|that's|this|let's|so|then|because|'cause|honestly|actually|okay|ok)\\b"
    /// Words after a comma that close or tag a phrase ("come along with, okay?"); the comma before them is real.
    static let tagWords = "(?i:okay|ok|right|yeah|yes|though|too|honestly|man|dude|bro|then|please|lol)\\b"

    /// Placeholders for spoken "new line" / "new paragraph" while the rules run (not letters, not whitespace).
    static let lineMark = "\u{E000}", paragraphMark = "\u{E001}"
    /// Joins the copies of a chant ("No way, no way, no way.") so the repeat rules leave it; removed before the end.
    static let chantMark = "\u{2060}"

    public static func apply(_ text: String, mode: CleanupMode, style: Style = .casual, keepSwearing: Bool = false) -> String {
        var s = text
        // 0a. "New paragraph." / "new line," said as its own phrase between sentence boundaries ("A new line of
        // shoes" stays). Marked now, turned into line breaks after the spacing rules.
        s = s.replacingOccurrences(of: "(?i)(^|[.!?,;:]\\s*)new paragraph[.,!?:;]*(?=\\s|$)", with: "$1 \(paragraphMark) ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)(^|[.!?,;:]\\s*)new line[.,!?:;]*(?=\\s|$)", with: "$1 \(lineMark) ", options: .regularExpression)
        // 0. A phrase restarted after a filler: "from your uh from our shared drive" -> "from our shared drive". The small
        // word said again right after the "uh" marks where the speaker started over; only one word is dropped with it.
        s = s.replacingOccurrences(of: "(?i)\\b(\(restartWords))\\s+[\\w']+,?\\s+(?:\(fillers)|er|ah)[,.]?\\s+(?=\\1\\s+\\w)", with: "",
                                   options: .regularExpression)
        // 0b. "I, uh, pressed that": the comma after a subject pronoun was only the pause before the filler.
        s = s.replacingOccurrences(of: "\\b(I|[Ww]e|[Yy]ou|[Tt]hey|[Hh]e|[Ss]he),\\s*(?i:\(fillers))[,.]?\\s+(?=[a-z])", with: "$1 ",
                                   options: .regularExpression)
        // 1. Leftover fillers, with the comma that came with them.
        s = s.replacingOccurrences(of: "(?i)(^|[\\s,])\(fillers)[,.]?(?=\\s|$)", with: "$1", options: .regularExpression)
        // 1b. "er", "ah", "eh" in the middle of a sentence are hesitations ("the total is, er, about"). Lowercase only,
        // so "the ER was packed" stays, and never at the start ("Ah, I see").
        s = s.replacingOccurrences(of: "(?<=[A-Za-z0-9])(?:,?\\s+(?:er|ah|eh)(?=[,.\\s]|$))+[,]?", with: "", options: .regularExpression)
        // 1b2. "The total is, are, about": "er" heard as "are" between commas after "is"/"was", which is never grammar.
        s = s.replacingOccurrences(of: "(?<=\\b(?:is|was|Is|Was)),\\s+are,(?=\\s)", with: ",", options: .regularExpression)
        // "a the keys": a hesitation heard as "a" before "the".
        s = s.replacingOccurrences(of: "\\b[Aa]n?\\s+(?=the\\b)", with: "", options: .regularExpression)
        // A leading "Ah," is a hesitation too when the speaker keeps hesitating ("Ah, I uh need uh the keys");
        // on its own it is a reaction and stays ("Ah, I see").
        if text.range(of: "(?i)\\b(?:uh|um|ah|er)\\b.*\\b(?:uh|um|ah|er)\\b.*\\b(?:uh|um|ah|er)\\b", options: .regularExpression) != nil {
            s = s.replacingOccurrences(of: "^(?:Ah|Eh),?\\s+", with: "", options: .regularExpression)
        }
        // 1c. "Aye, I, I": a stuttered "I" written as "Aye".
        s = s.replacingOccurrences(of: "(?i)(^|[.!?]\\s+)aye,?\\s+(?=i\\b)", with: "$1", options: .regularExpression)
        // 1d. A false start: an unfinished clause ending on a small word, then the same speaker starts again.
        // "I went to the, I drove to the store" -> "I drove to the store". "I went to the store, I bought milk" stays.
        s = s.replacingOccurrences(of: "(?i)(^|[.!?]\\s+)(i|we|you|he|she|they|it)\\s+(?:[\\w']+\\s+){0,3}(?:the|a|an|to|of|for|with|in|on|at|and|my|your|our|their),\\s+(?=\\2\\b)",
                                   with: "$1", options: .regularExpression)
        // Without the comma only after "the/a/my...": "I went to the I drove" (a determiner never comes before "I").
        s = s.replacingOccurrences(of: "(^|[.!?]\\s+)(I)\\s+(?:[\\w']+\\s+){0,3}(?:the|a|an|my|your|our|their)\\s+(?=I(?:'m|'ll|'ve|'d|\\s+(?:\(restartVerbs))\\b))",
                                   with: "$1", options: .regularExpression)
        // 1e. A word cut off as the speaker starts the phrase again: "when we w when we finish" -> "when we when we finish"
        // (the repeat is removed next).
        s = cutOffRestarts(s)
        // 2. Words repeated as a false start: "we could, we could maybe" and "at the, the place". Until nothing changes,
        // so a stumble said three times ("we could, we could, we could try") ends as one copy, not two. A phrase said three
        // or more times that ends its sentence ("No way, no way, no way.") is meant, and is marked so this leaves it.
        s = markChants(s)
        var before = ""
        while before != s {
            before = s
            s = s.replacingOccurrences(of: "(?i)\\b(\\w+(?:\\s+\\w+){1,2}),\\s+\\1\\b", with: "$1", options: .regularExpression)
        }
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
        // 2f. "like" as a filler, only where it cannot be the verb or a comparison.
        s = fillerLike(s)
        // 2g. The professional style's extra cleanup (PLAN-v1 P2). Casual text never reaches it.
        if style == .professional { s = professional(s, keepSwearing: keepSwearing) }
        // 3. Commas stranded after small words where a filler used to be: "meet on, Thursday".
        // "on" and "in" also end phrasal verbs ("Hold on, I'll check", "Log in, then click save", "come in, sit down"),
        // so they lose the comma only before a determiner, a number or a capitalized name.
        s = s.replacingOccurrences(of: "(?i)\\b(\(joiners)),\\s+(?!\(tagWords))(?=\\w)", with: "$1 ", options: .regularExpression)
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
        s = s.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // 4c. Spoken breaks become real ones. A paragraph after a sentence that didn't end gets its full stop.
        if s.contains(lineMark) || s.contains(paragraphMark) {
            let endsSentence = mode == .ai ? "" : "."
            s = s.replacingOccurrences(of: "(?<=[A-Za-z0-9])[,;:]?\\s*\(paragraphMark)", with: endsSentence + paragraphMark, options: .regularExpression)
            s = s.replacingOccurrences(of: "[,;:]?\\s*\(paragraphMark)\\s*", with: "\n\n", options: .regularExpression)
            s = s.replacingOccurrences(of: "[,;:]?\\s*\(lineMark)\\s*", with: "\n", options: .regularExpression)
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if mode == .email { s = emailLayout(s) }
        // 4b. A dictation never ends on a comma or semicolon ("...pack the bags for the trip,"): end it the way the mode ends
        // a trailed-off sentence (step 2e).
        if let last = s.last, last == "," || last == ";" {
            let cut = String(s.dropLast()).trimmingCharacters(in: .whitespaces)
            if !cut.isEmpty { s = cut + (mode == .ai ? "" : ".") }
        }
        s = s.replacingOccurrences(of: chantMark, with: "")
        guard !s.isEmpty else { return s }
        // 5. Capital letters at the start and after sentence ends.
        s = capitalizeSentences(s)
        // 6. Text for people ends like a sentence.
        if mode.isForPeople, let last = s.last, !".!?:)\"'".contains(last), !emailSignedOff(s) { s += "." }
        // 7. Professional: a list you said ("first..., second...", "three things: a, b and c") becomes a real one.
        if style == .professional { s = spokenList(countedList(s)) }
        return s
    }

    /// The professional style's rules (PLAN-v1 P2). Each was read against every match in 677 real dictations before
    /// it was turned on; the misses that reading found are the exclusions written into the patterns.
    static func professional(_ text: String, keepSwearing: Bool) -> String {
        var s = text
        func re(_ pattern: String, _ template: String) {
            s = s.replacingOccurrences(of: "(?i)" + pattern, with: template, options: .regularExpression)
        }
        let start = "(^|[.!?]\\s+)"
        // Spoken forms written out. "it's gotta" is "it has to", not "it's have to".
        re("\\b(there|it|that|he|she)'s\\s+gotta\\b", "$1 has to")
        for (spoken, written) in [("wanna", "want to"), ("gonna", "going to"), ("gotta", "have to"), ("kinda", "kind of"),
                                  ("sorta", "sort of"), ("lemme", "let me"), ("gimme", "give me"), ("dunno", "don't know"),
                                  ("'cause", "because"), ("cuz", "because"), ("cos", "because")] {
            re("(?<![\\w'])" + NSRegularExpression.escapedPattern(for: spoken) + "(?![\\w'])", written)
        }
        // "cause" only where it is "because": opening a clause ("the cause of" stays).
        re("(^|[.!?,]\\s+)cause\\s+(?=(?:i|we|you|they|he|she|it|it's|that's|there's|this|that)\\b)", "$1because ")
        re("\\b(for|to|with|at|see|thank|tell|love|miss|help|let|got)\\s+ya\\b", "$1 you")
        // Tag fillers: "..., you know?", "or whatever", "and stuff", "I mean, ...".
        re(",?\\s*you know\\?(?=\\s|$)", ".")
        re(",\\s*you know,\\s*", ", ")
        re(",\\s*you know(?=[.!?]|$)", "")
        re(start + "you know,\\s+", "$1")
        re(",?\\s+or whatever(?=[.!?,]|$)", "")
        re(",?\\s+and (?:stuff|shit)(?: like that)?(?=[.!?,]|$)", "")
        re(start + "I mean,\\s+", "$1")
        re(start + "I mean\\s+(?=(?:if|it's|that's|we|you|they|the|honestly|obviously|i|there's|this|yeah)\\b)", "$1")
        // Exclamations that are only emphasis.
        if !keepSwearing { re(start + "(?:god ?damn|damn) it[,.!]*\\s*", "$1") }
        re(start + "oh my god[,.!]*\\s*", "$1")
        // Openers and forms of address, as many as are stacked ("Oh yeah, ...", "Alright, yeah, ..."). "So" only
        // when it opens a clause: "So far", "So weird" and "So much" stay.
        var previous = ""
        while previous != s {
            previous = s
            re(start + "(?:yeah|yep|yup|okay so|ok so|alright|all right|dude|bro|man|big dog|ah|oh)(?:,\\s*|\\s+)(?=\\w)", "$1")
            re(start + "so(?:,\\s*|\\s+(?=(?:we|i|you|they|he|she|it|let's|that's|it's|there's|this|if|yeah)\\b))", "$1")
        }
        re(",\\s*(?:dude|bro|man|big dog|brother|my brother|buddy|bud|my guy|homie)(?=[.!?,]|$)", "")
        // Swearing used for emphasis. Not where it is the verb ("they kept f***ing the order up").
        if !keepSwearing {
            re("\\b(?:fucking|fuckin'?|freaking|frickin'?|goddamn|god damn|damn)\\s+(?!(?:it|up|around|with|over|off|me|him|her|them|us|you)\\b)(?!(?:\\w+\\s+){1,2}(?:up|over|around|off)\\b)(?=\\w)", "")
            re("\\bshit like that\\b", "things like that")
            re("\\b(the|this|that|my|your|our|his|her|their)\\s+shit\\b", "$1 stuff")
        }
        // "like" the shared rules leave because it can be a comparison in casual speech.
        re("\\b(it's|it is|it was|that's|that is|is|was)\\s+like,?\\s+(?=(?:can|could|will|would|should|almost|really|so|very|super|totally|pretty|literally|just|not|kind of|sort of)\\b)", "$1 ")
        re("\\balmost like\\s+(?=\\w+ed\\b)", "almost ")
        re("\\b(can|could|will|would|should|must|might)\\s+be\\s+like\\s+(?=\\w)", "$1 be ")
        // What the removals leave behind: a comma before a full stop, a doubled mark.
        re(",\\s*([.!?])", "$1")
        re("([!?])\\s*\\.", "$1")
        // Never hand back nothing: a dictation that was only an opener ("Yeah.") stays as it was.
        return s.rangeOfCharacter(from: .letters) == nil ? text : s
    }

    /// Drops "like" where it is only a filler: "to like talk", "for like the whole day", "or like vendors",
    /// "build like a demo", "my like calendar", "Like, does that matter?". It stays wherever it can be the verb
    /// ("I honestly like both"), a comparison ("looks like", "feel like", "it's like a", "more like", "just like",
    /// "like that") or a quotation ("she was like, no"). Each pattern was read against every "like" in 677 real
    /// dictations before it was turned on: 71 removed of 254, none of them a verb or a comparison.
    static func fillerLike(_ text: String) -> String {
        guard text.range(of: "like", options: .caseInsensitive) != nil else { return text }
        let prep = "for|in|on|at|with|of|about|from|by|into|over|around|through|after|before|than|within|during"
        let conj = "and|or|but|so|because|cause|'cause|then|when|if|while|where|which|plus"
        let verbs = "make|made|making|have|has|had|having|get|got|getting|use|used|using|need|needs|want|wanna|build|built|add|added|"
            + "see|saw|take|takes|took|give|gave|put|buy|bought|write|wrote|create|created|run|ran|try|tried|find|found|pay|paid|"
            + "spend|spent|post|posted|send|sent|cut|pick|picked|show|showed|keep|kept|gonna|gotta"
        let det = "a|an|the|my|your|our|their|his|her|its|some|any|every|all|two|three|four|five|six|seven|eight|nine|ten|one|another|"
            + "each|both|\\d[\\d,.]*%?"
        let obj = "that|this|these|those|it|him|her|me|us|them|mine|yours|so"
        let baseVerbs = "speak|talk|say|tell|do|make|have|get|go|come|see|look|use|try|put|take|give|show|send|post|write|read|build|"
            + "run|start|stop|keep|let|help|work|play|move|add|change|check|find|think|know|feel|want|need|ask|call|open|close|set|"
            + "turn|pull|push|cut|pay|buy|sell|bring|leave|meet|learn|test|fix|ship|update|create|explore|explain|share|record|edit|"
            + "finish|wait|watch|listen|pick|click|press|hold|drop|drag|scroll|type|copy|paste|save|load|install|download|upload|"
            + "deploy|merge|commit|review|plan|design|draw|render|zoom|crash|restart|reset|switch|compare|measure|count|track|"
            + "handle|manage|focus|optimize|translate|convert"
        // "Like I said" and "like you said" mean "as": never a filler.
        let notAs = "(?!\\s+(?:i|you|we)\\s+(?:said|say|was saying|were saying|mentioned|told))"
        let opener = "it's|i'm|we're|you're|they're|there's|that's|if|do|did|does|is|are|can|could|should|would|will|maybe|right now|"
            + "literally|honestly|basically|obviously|sometimes"
        let afterPronoun = "don't|didn't|can't|can|feel|think|mean|guess|just|was|had|have|would|could|really|literally|never|kinda|"
            + "still|also|actually|wanna|want|need"
        let start = "(^|[.!?]\\s+)"
        let rules: [(String, String)] = [
            // After a preposition ("of like mind" and "in like manner" are the old adjective).
            ("\\b(\(prep))\\s+like,?\\s+(?!mind\\b|minds\\b|manner\\b|kind\\b)(?=[\\w$])", "$1 "),
            // After a conjunction, unless an object follows ("and like that, it was gone").
            ("\\b(\(conj)),?\\s+like,?\(notAs)\\s+(?!(?:\(obj))\\b)(?=[\\w$])", "$1 "),
            // A verb, "like", then a determiner or number: "build like a demo".
            ("\\b(\(verbs))\\s+like,?\\s+(?=(?:\(det))\\b)", "$1 "),
            // "to like talk": "to like" before a plain verb.
            ("\\bto\\s+like,?\\s+(?=(?:\(baseVerbs))\\b)", "to "),
            // Set off by commas, or opening a sentence with a comma after it.
            (",\\s+like,\\s+", ", "),
            (start + "like,\\s+", "$1"),
            // Opening a clause: "Like it's ...", ", like is that ...", "Like what?", "Like I can't tell".
            ("(^|[.!?]\\s+|,\\s+)like\\s+(?=(?:\(opener))\\b)", "$1"),
            (start + "like\\s+(?=(?:what|how|why|when|where)\\b)", "$1"),
            (start + "like\\s+(?=(?:i|we|he|she|they)\\s+(?:\(afterPronoun))\\b)", "$1"),
            // "my like calendar", "you're like making", "maybe like trying", "it was already like done".
            ("\\b(my|your|our|their|his|its|any)\\s+like\\s+(?=\\w)", "$1 "),
            ("\\b(i'm|you're|we're|they're)\\s+like,?\\s+(?=\\w+ing\\b)", "$1 "),
            ("\\b(maybe)\\s+like,?\\s+(?!(?:\(obj)|\(det))\\b)(?=\\w)", "$1 "),
            ("(?<!\\bi )(?<!\\byou )(?<!\\bwe )(?<!\\bthey )\\b(already|basically)\\s+like,?\\s+(?!(?:\(obj)|\(det))\\b)(?=\\w)", "$1 "),
            // "they like kind of ignore": never before "kind of" ("I'd like kind of a quiet place" keeps it).
            ("(?<!would )(?<!'d )\\blike\\s+(?=(?:kind of|sort of|kinda|sorta)\\b)", ""),
        ]
        var s = text
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: "(?i)" + pattern, with: template, options: .regularExpression)
        }
        return s
    }

    /// "No way, no way, no way." / "Go team go team go team!": one to three words said three or more times, ending the
    /// sentence. Meant, so the copies are joined with `chantMark` and the repeat rules below don't see a repeat. A
    /// single stutter word ("and then I, I, I.") is not a chant.
    static func markChants(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "(?i)\\b([\\w']+(?:\\s+[\\w']+){0,2})((?:,?\\s+\\1\\b){2,})(?=\\s*(?:[.!?]|$))")
        else { return text }
        let stutters = Set(stutterWords.split(separator: "|").map(String.init))
        var s = text
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let phrase = Range(m.range(at: 1), in: s), let copies = Range(m.range(at: 2), in: s) else { continue }
            if stutters.contains(s[phrase].lowercased()) { continue }
            let joined = s[copies].replacingOccurrences(of: "(,?)(\\s+)", with: "$1\(chantMark)$2", options: .regularExpression)
            s.replaceSubrange(copies, with: joined)
        }
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
            if ch == "\n" { capNext = true }
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

