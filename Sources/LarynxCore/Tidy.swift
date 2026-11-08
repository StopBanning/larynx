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
    static let fillers = "(?:u+m+|u+h+m*|e+r+m+|h+m+|m+h+m*)"
    static let joiners = "to|on|at|in|of|for|with|from|about|the|a|an|and|but|or|is|was|are|were|be|my|your|our|their"

    public static func apply(_ text: String, mode: CleanupMode) -> String {
        var s = text
        // 1. Leftover fillers, with the comma that came with them.
        s = s.replacingOccurrences(of: "(?i)(^|[\\s,])\(fillers)[,.]?(?=\\s|$)", with: "$1", options: .regularExpression)
        // 2. Words repeated as a false start: "we could, we could maybe" and "at the, the place".
        s = s.replacingOccurrences(of: "(?i)\\b(\\w+(?:\\s+\\w+){1,2}),\\s+\\1\\b", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)\\b(\\w+),?\\s+\\1\\b", with: "$1", options: .regularExpression)
        // 3. Commas stranded after small words where a filler used to be: "meet on, Thursday".
        s = s.replacingOccurrences(of: "(?i)\\b(\(joiners)),\\s+(?=\\w)", with: "$1 ", options: .regularExpression)
        // 4. Spacing and doubled punctuation.
        s = s.replacingOccurrences(of: "\\s*,\\s*,+", with: ",", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+([,.!?;:])", with: "$1", options: .regularExpression)
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

    static func capitalizeSentences(_ s: String) -> String {
        var out = ""
        var capNext = true
        for ch in s {
            if capNext, ch.isLetter { out += ch.uppercased(); capNext = false; continue }
            if ".!?".contains(ch) { capNext = true } else if !ch.isWhitespace { capNext = false }
            out.append(ch)
        }
        return out
    }
}
