import AppKit
import Foundation

/// How much to polish, chosen from the app you are dictating into.
public enum CleanupMode: String, Sendable {
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

    /// The app that will receive the text right now.
    public static func frontmost() -> (bundleID: String?, mode: CleanupMode) {
        let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return (id, forApp(bundleID: id))
    }
}

/// Rule-based tidy-up: instant, and it never rewrites a real word.
public enum Tidy {
    static let fillers = "(?:u+m+|u+h+m*|e+r+m+|h+m+)"
    /// Words people stutter on. Doubles of other words ("very very", "had had", "that that", "no no") are left alone.
    static let stutterWords = "the|a|an|to|i|we|you|it|is|and|of|in|on|for|my|our|can|so|but|or|if|he|she|they|this|at|with|be"
    static let joiners = "to|on|at|in|of|for|with|from|about|the|a|an|and|but|or|is|was|are|were|be|my|your|our|their"

    public static func apply(_ text: String, mode: CleanupMode) -> String {
        var s = text
        // 1. Leftover fillers, with the comma that came with them.
        s = s.replacingOccurrences(of: "(?i)(^|[\\s,])\(fillers)[,.]?(?=\\s|$)", with: "$1", options: .regularExpression)
        // 2. Words repeated as a false start: "we could, we could maybe" and "at the, the place".
        s = s.replacingOccurrences(of: "(?i)\\b(\\w+(?:\\s+\\w+){1,2}),\\s+\\1\\b", with: "$1", options: .regularExpression)
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
        s = s.replacingOccurrences(of: "(?i)\\b(\(joiners)),\\s+(?=\\w)", with: "$1 ", options: .regularExpression)
        // 4. Spacing and doubled punctuation.
        s = s.replacingOccurrences(of: "\\s*,\\s*,+", with: ",", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+([,!?;:]|\\.(?![A-Za-z]))", with: "$1", options: .regularExpression)  // but not ".env"
        s = s.replacingOccurrences(of: "^[\\s,.;:]+", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }
        // 5. Capital letters at the start and after sentence ends.
        s = capitalizeSentences(s)
        // 6. Text for people ends like a sentence.
        if mode == .correspondence, let last = s.last, !".!?:)\"'".contains(last) { s += "." }
        return s
    }

    static let questionOpeners = "can|could|will|would|should|do|did|shall"

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

/// Your words: "heard this" -> "write that", whole words, any capitalization.
/// Lives in ~/Library/Application Support/Larynx/dictionary.json, e.g. {"lynx": "Larynx", "locust app": "Locust"}.
public enum Dictionary {
    public static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Larynx/dictionary.json")

    public static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return map
    }

    /// Adds or replaces one entry and saves the file.
    public static func add(heard: String, written: String) throws {
        ensureExists()
        var map = load()
        map[heard.lowercased()] = written
        let data = try JSONSerialization.data(withJSONObject: map, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    /// Creates the file with a starter entry if it doesn't exist yet.
    public static func ensureExists() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("{\n  \"lynx\": \"Larynx\",\n  \"larynx\": \"Larynx\"\n}\n".utf8).write(to: url)
    }

    public static func apply(_ text: String, map: [String: String] = load()) -> String {
        var s = text
        // Longest phrases first so "locust app" wins over "locust".
        for (heard, written) in map.sorted(by: { $0.key.count > $1.key.count }) {
            let pattern = "(?i)\\b" + NSRegularExpression.escapedPattern(for: heard) + "\\b"
            s = s.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: written), options: .regularExpression)
        }
        return s
    }
}
