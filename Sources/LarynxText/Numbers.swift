import Foundation

/// Spoken numbers to digits, without an AI model: "ninety-four" -> "94", "five point two" -> "5.2",
/// "three percent" -> "3%", "twenty dollars" -> "$20", "seven thirty pm" -> "7:30 PM", "twenty twenty-six" -> "2026".
///
/// Deliberately conservative (NeMo's inverse normalization was too eager): small numbers stay words ("one of them",
/// "two things", "in three days") unless a unit or a label makes them a number ("3%", "step 2", "top 5", "iOS 18").
public enum Numbers {
    static let units: [String: Int] = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19]
    static let tens: [String: Int] = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
        "eighty": 80, "ninety": 90]
    static let scales: [String: Int] = ["hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]
    /// Words before a number that make it a number even when small: "step 2", "version 3", "Opus 5".
    static let labels: Set<String> = ["version", "step", "item", "line", "page", "chapter", "port", "level", "phase",
        "top", "section", "figure", "option", "round", "season", "episode", "issue", "ios", "macos", "iphone", "ipad",
        "windows", "android", "gpt", "opus", "sonnet", "haiku", "fable", "claude", "gemini", "llama", "python", "pixel"]
    static let timeBefore: Set<String> = ["at", "by", "around", "until", "till", "from", "before", "after", "since"]
    static let timeAfter: Set<String> = ["pm", "am", "tonight", "tomorrow", "today", "o'clock", "sharp"]

    struct Token { var lead: String; var core: String; var trail: String }
    struct Rendered { var text: String; var consumesNext = false; var absorbsArticle = false }

    /// "Hindsight is twenty twenty", "twenty twenty vision": the eyesight score, not the year. Speech models write
    /// "2020" here, so both spellings are handled.
    static func idioms(_ text: String) -> String {
        let score = "(?:2020|twenty[- ]twenty)"
        var s = text.replacingOccurrences(of: "(?i)\\b(hindsight(?:'s|\\s+is|\\s+was|\\s+being)\\s+)\(score)\\b", with: "$120/20",
                                          options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)\\b\(score)(\\s+(?:vision|eyesight|hindsight))\\b", with: "20/20$1", options: .regularExpression)
        return s
    }

    public static func apply(_ text: String) -> String {
        let t = tokenize(idioms(text))
        var out: [Token] = []
        var i = 0
        while i < t.count {
            guard let span = numberSpan(t, from: i) else { out.append(t[i]); i += 1; continue }
            let endsWithBreak = hasBreak(t[span.end - 1].trail)
            let prev = out.last.flatMap { hasBreak($0.trail) ? nil : norm($0.core) } ?? ""
            let next = !endsWithBreak && span.end < t.count ? norm(t[span.end].core) : ""
            guard let r = render(span.words, prev: prev, next: next) else {
                out.append(contentsOf: t[span.start..<span.end]); i = span.end; continue
            }
            var lead = t[span.start].lead
            if r.absorbsArticle, let last = out.last, ["a", "an"].contains(norm(last.core)) {
                out.removeLast()
                lead = last.lead + lead
            }
            var trail = r.consumesNext ? t[span.end].trail : t[span.end - 1].trail
            // "p.m." ends in its own dot: keep it only where a sentence ends ("at 7 PM." / "at 7 PM tomorrow").
            if r.consumesNext, t[span.end].core.contains("."), trail.hasPrefix(".") {
                let after = span.end + 1 < t.count ? t[span.end + 1].core.first : nil
                if let after, !after.isUppercase { trail.removeFirst() }
            }
            out.append(Token(lead: lead, core: r.text, trail: trail))
            i = span.end + (r.consumesNext ? 1 : 0)
        }
        var s = out.map { $0.lead + $0.core + $0.trail }.joined()
        // Digits the speech model already wrote: "3 percent" -> "3%", "20 dollars" -> "$20".
        s = s.replacingOccurrences(of: "(?i)\\b(\\d+(?:\\.\\d+)?) percent\\b", with: "$1%", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)(?<![$\\d.,])\\b(\\d+(?:\\.\\d+)?) (?:dollars|bucks)\\b", with: "\\$$1", options: .regularExpression)
        // "Y two K" / "why two K" is the year-2000 thing.
        s = s.replacingOccurrences(of: "(?i)\\b(?:y|why) 2K\\b", with: "Y2K", options: .regularExpression)
        return s
    }

    static func norm(_ core: String) -> String { core.lowercased().replacingOccurrences(of: ".", with: "") }
    static func hasBreak(_ trail: String) -> Bool { !trail.trimmingCharacters(in: .whitespaces).isEmpty }
    static func isNumberWord(_ w: String) -> Bool { units[w] != nil || tens[w] != nil || scales[w] != nil }

    /// A run of number words starting at `i` ("ninety four", "two hundred and fifty", "five point two", "seven oh five").
    static func numberSpan(_ t: [Token], from i: Int) -> (start: Int, end: Int, words: [String])? {
        var words: [String] = []
        var j = i
        while j < t.count {
            if j > i, !t[j].lead.isEmpty { break }
            let w = t[j].core.lowercased()
            let parts = w.split(separator: "-").map(String.init)
            if !parts.isEmpty, parts.allSatisfy(isNumberWord) {
                words += parts
            } else if !words.isEmpty, ["and", "point", "oh"].contains(w), j + 1 < t.count, !hasBreak(t[j].trail),
                      t[j + 1].core.lowercased().split(separator: "-").allSatisfy({ units[String($0)] != nil || tens[String($0)] != nil }),
                      w != "and" || words.last.map({ scales[$0] != nil }) == true {
                words.append(w)
            } else { break }
            j += 1
            if hasBreak(t[j - 1].trail) { break }  // a comma or full stop ends the number
        }
        return words.isEmpty ? nil : (i, j, words)
    }

    /// Whether and how a span becomes digits.
    static func render(_ words: [String], prev: String, next: String) -> Rendered? {
        if words.contains("point") { return decimal(words, next: next) }
        if let r = clock(words, prev: prev, next: next) { return r }
        if let y = year(words) { return Rendered(text: y) }
        guard let n = value(words) else { return nil }
        // "a hundred percent" -> 100%, but "about a hundred people", "a million thanks", "hundreds" stay words.
        let startsWithScale = scales[words[0]] != nil
        if startsWithScale, prev != "a", prev != "an" { return nil }
        // Plain numbers become digits from 11 up ("ten out of ten" and "the ten commandments" read better as words).
        let force = !startsWithScale && (n > 10 || labels.contains(prev))
        guard var r = withUnit(format(n, words: words), value: Double(n), next: next, force: force) else { return nil }
        r.absorbsArticle = startsWithScale
        return r
    }

    static func decimal(_ words: [String], next: String) -> Rendered? {
        var words = words
        var scaleWord = ""
        if let last = words.last, last == "million" || last == "billion" { scaleWord = " " + last; words.removeLast() }
        guard let p = words.firstIndex(of: "point"), let whole = value(Array(words[..<p])) else { return nil }
        let fraction = words[(p + 1)...]
        let digits = fraction.compactMap { units[$0] }
        guard !digits.isEmpty, digits.count == fraction.count, digits.allSatisfy({ $0 < 10 }) else { return nil }
        let n = "\(whole)." + digits.map(String.init).joined()
        return withUnit(n + scaleWord, value: Double(n) ?? 0, next: next, force: true)
    }

    /// A unit after the number ("3%", "$20", "200K", "20x", "7 PM", "16 GB"), or plain digits when `force`.
    static func withUnit(_ n: String, value: Double, next: String, force: Bool) -> Rendered? {
        switch next {
        case "percent": return Rendered(text: n + "%", consumesNext: true)
        case "dollars", "dollar", "bucks": return Rendered(text: "$" + n, consumesNext: true)
        case "k", "grand": return Rendered(text: n + "K", consumesNext: true)
        case "x": return Rendered(text: n + "x", consumesNext: true)
        case "pm", "am": return value <= 12 ? Rendered(text: n + " " + next.uppercased(), consumesNext: true) : nil
        case "o'clock": return value <= 12 ? Rendered(text: n + " o'clock", consumesNext: true) : nil
        case "gb", "mb", "tb", "kb": return Rendered(text: n + " " + next.uppercased(), consumesNext: true)
        case "ms", "px", "fps", "gigs", "cents": return Rendered(text: n + " " + next, consumesNext: true)
        default: return force ? Rendered(text: n) : nil
        }
    }

    /// "seven thirty", "ten oh five": only after at/by/around... or before pm/tonight..., so "seven thirty-somethings" stays.
    static func clock(_ words: [String], prev: String, next: String) -> Rendered? {
        guard words.count >= 2, let h = units[words[0]], (1...12).contains(h) else { return nil }
        let rest = Array(words.dropFirst())
        var minutes: Int?
        if rest.count == 2, rest[0] == "oh", let m = units[rest[1]], (1...9).contains(m) { minutes = m }
        else if let m = value(rest), (10...59).contains(m), !rest.contains(where: { scales[$0] != nil }) { minutes = m }
        // "move it to eleven fifteen": after "to", only quarter and half hours, so "up to five forty" stays a number.
        guard let m = minutes, timeBefore.contains(prev) || timeAfter.contains(next) || (prev == "to" && [15, 30, 45].contains(m))
        else { return nil }
        let text = "\(h):" + (m < 10 ? "0\(m)" : "\(m)")
        if next == "pm" || next == "am" { return Rendered(text: text + " " + next.uppercased(), consumesNext: true) }
        return Rendered(text: text)
    }

    /// "nineteen ninety", "twenty twenty-six", "nineteen oh five".
    static func year(_ words: [String]) -> String? {
        guard words.count >= 2, let c = ["eighteen": 18, "nineteen": 19, "twenty": 20][words[0]] else { return nil }
        let rest = Array(words.dropFirst())
        if rest.count == 2, rest[0] == "oh", let y = units[rest[1]], (1...9).contains(y) { return "\(c)0\(y)" }
        guard rest.allSatisfy({ units[$0] != nil || tens[$0] != nil }), let y = value(rest), (10...99).contains(y) else { return nil }
        if c == 20, rest.count == 1, tens[rest[0]] == nil { return nil }  // "twenty five" is 25, not a year
        return "\(c)\(y)"
    }

    /// The value of number words, or nil when they aren't one number ("five six" is two numbers, "oh" isn't a digit here).
    static func value(_ words: [String]) -> Int? {
        enum Kind { case none, unit, ten, hundred, scale }
        var total = 0, current = 0, last = Kind.none
        for w in words where w != "and" {
            if let u = units[w] {
                switch last {
                case .unit: return nil
                case .ten: guard (1...9).contains(u) else { return nil }
                default: break
                }
                current += u; last = .unit
            } else if let t = tens[w] {
                guard last != .unit, last != .ten else { return nil }
                current += t; last = .ten
            } else if w == "hundred" {
                guard last == .unit || last == .none, current < 10 else { return nil }
                current = max(current, 1) * 100; last = .hundred
            } else if let s = scales[w] {
                total += max(current, 1) * s; current = 0; last = .scale
            } else { return nil }
        }
        return words.contains(where: { $0 != "and" }) ? total + current : nil
    }

    static func format(_ n: Int, words: [String]) -> String {
        if let last = words.last, let s = scales[last], s >= 1_000_000, n % s == 0 { return "\(n / s) \(last)" }  // "2 million"
        guard n >= 10_000 else { return String(n) }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// Words with their leading and trailing punctuation and the space after them, so the text rebuilds exactly.
    static func tokenize(_ s: String) -> [Token] {
        guard let re = try? NSRegularExpression(pattern: "\\S+\\s*") else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            guard let r = Range(m.range, in: s) else { return nil }
            let piece = String(s[r])
            let word = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            let space = String(piece.dropFirst(word.count))
            let lead = String(word.prefix { !$0.isLetter && !$0.isNumber })
            let afterLead = word.dropFirst(lead.count)
            let trailCount = afterLead.reversed().prefix { !$0.isLetter && !$0.isNumber && $0 != "'" }.count
            let core = String(afterLead.dropLast(trailCount))
            return Token(lead: lead, core: core, trail: String(afterLead.suffix(trailCount)) + space)
        }
    }
}
