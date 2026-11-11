import Foundation

/// Learns from saying something again. When you dictate a sentence and then, within a minute or so, say it again with
/// a word changed ("Tell Logus to start" ... "Tell Locust to start"), the change is almost always a fix for a
/// mishearing. This finds those changes and decides what is safe to learn.
///
/// Safe means: the replaced word was not a real English word (the speech model invented "Logus" or "Golang"), so
/// mapping it in the dictionary can never change a word you meant. When both words are real ("send"/"sent",
/// "Tuesday"/"Wednesday") you probably changed your mind, so nothing is learned automatically.
public enum Corrections {
    public struct Change: Equatable, Sendable {
        public let heard: String
        public let meant: String
        public init(heard: String, meant: String) { self.heard = heard; self.meant = meant }
    }

    public enum Lesson: Equatable, Sendable {
        /// Write `meant` whenever `heard` comes out (`heard` is not a real word, so this is always safe).
        case dictionary(heard: String, meant: String)
        /// Listen harder for `meant` (a name or term the speech model doesn't know).
        case vocabulary(String)
        /// Both are real words: shown for review, never applied by itself.
        case suggestion(heard: String, meant: String)
    }

    /// Word swaps between a dictation and the one that repeated it. Empty unless the two are clearly the same
    /// sentence (at least 3 words, at least 60% of words in common, at most 2 places changed).
    public static func changes(previous: String, current: String) -> [Change] {
        let a = tokens(previous), b = tokens(current)
        guard a.count >= 3, b.count >= 3 else { return [] }
        let la = a.map { $0.lowercased() }, lb = b.map { $0.lowercased() }
        // Longest common subsequence of words.
        var dp = Array(repeating: Array(repeating: 0, count: lb.count + 1), count: la.count + 1)
        for i in stride(from: la.count - 1, through: 0, by: -1) {
            for j in stride(from: lb.count - 1, through: 0, by: -1) {
                dp[i][j] = la[i] == lb[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        let common = dp[0][0]
        guard Double(common) / Double(max(la.count, lb.count)) >= 0.6, common < max(la.count, lb.count) || la.count != lb.count
        else { return [] }
        // Walk the alignment and collect the stretches where the two differ.
        var blocks: [([String], [String])] = []
        var i = 0, j = 0, gapA: [String] = [], gapB: [String] = []
        func flush() {
            if !gapA.isEmpty || !gapB.isEmpty { blocks.append((gapA, gapB)) }
            gapA = []; gapB = []
        }
        while i < la.count || j < lb.count {
            if i < la.count, j < lb.count, la[i] == lb[j] { flush(); i += 1; j += 1 }
            else if j < lb.count, i == la.count || dp[i][j + 1] >= dp[i + 1][j] { gapB.append(b[j]); j += 1 }
            else { gapA.append(a[i]); i += 1 }
        }
        flush()
        // Words added at the very start or end ("Alright, ...", "... yo") are not fixes.
        blocks.removeAll { $0.0.isEmpty || $0.1.isEmpty }
        guard (1...2).contains(blocks.count) else { return [] }
        return blocks.compactMap { heard, meant in
            guard (1...2).contains(heard.count), meant.count == 1 else { return nil }
            return Change(heard: heard.joined(separator: " "), meant: meant[0])
        }
    }

    /// What to learn from each change.
    public static func lessons(_ changes: [Change], words: any WordList) -> [Lesson] {
        var out: [Lesson] = []
        for c in changes {
            let heard = c.heard, meant = c.meant
            guard heard.lowercased() != meant.lowercased(), meant.count >= 2,
                  meant.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" }),
                  soundAlike(heard, meant) else { continue }
            let heardWords = heard.split(separator: " ").map(String.init)
            let invented = heardWords.contains { !words.contains($0) }
            let meantIsWord = words.contains(meant)
            if invented {
                out.append(.dictionary(heard: heard, meant: meant))
                if !meantIsWord { out.append(.vocabulary(meant)) }
            } else if !meantIsWord {
                out.append(.vocabulary(meant))
            } else {
                out.append(.suggestion(heard: heard, meant: meant))
            }
        }
        return out
    }

    /// Same first letter and close spelling: "Logus"/"Locust", "Golang"/"going", "go lang"/"Golang", "Gavy"/"Govee".
    /// Looser than the vocabulary swap, because here the user said the right word out loud.
    public static func soundAlike(_ heard: String, _ meant: String) -> Bool {
        let x = Array(heard.lowercased().filter(\.isLetter)), y = Array(meant.lowercased().filter(\.isLetter))
        guard x.count >= 2, y.count >= 2, x[0] == y[0] else { return false }
        if distance(x, y) <= max(2, max(x.count, y.count) / 3) { return true }
        // Vowels are what speech models get wrong most: "Gavy"/"Govee" share every consonant.
        let cx = x.filter { !"aeiouy".contains($0) }, cy = y.filter { !"aeiouy".contains($0) }
        return cx.count >= 2 && cy.count >= 2 && distance(cx, cy) <= 1
    }

    static func distance(_ x: [Character], _ y: [Character]) -> Int {
        guard !x.isEmpty else { return y.count }
        guard !y.isEmpty else { return x.count }
        var d = Array(0...y.count)
        for i in 1...x.count {
            var prev = d[0]; d[0] = i
            for k in 1...y.count {
                let cur = min(d[k] + 1, d[k - 1] + 1, prev + (x[i - 1] == y[k - 1] ? 0 : 1))
                prev = d[k]; d[k] = cur
            }
        }
        return d[y.count]
    }

    static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'-"))) }
            .filter { !$0.isEmpty }
    }
}
