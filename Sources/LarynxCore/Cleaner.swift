import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The AI rewrite layer. It runs only when the tidy rules can't do the job (a self-correction, spoken numbers,
/// a verbal tic) and only for text a person will read. Every reply passes a guard that rejects answers,
/// additions and big deletions, falling back to the tidied text.
public enum Cleaner {
    // MARK: When to rewrite

    static let correctionCues = #"(?i)\b(no wait|wait no|scratch that|make that|or rather|let me rephrase|sorry|actually|i mean)\b"#
    static let ticCues = #"(?i)\b(you know|kind of like|sort of like|basically|literally|like,)"#
    static let numberCues = #"(?i)\b(zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|percent|dollars?|cents?|o'clock)\b"#

    /// Why a rewrite is worth it, or nil when the tidy rules are enough.
    public static func reason(for text: String, mode: CleanupMode) -> String? {
        guard mode != .ai else { return nil }  // models reading it don't care
        if text.range(of: correctionCues, options: .regularExpression) != nil { return "correction" }
        if text.range(of: ticCues, options: .regularExpression) != nil { return "verbal tic" }
        if text.range(of: numberCues, options: .regularExpression) != nil { return "numbers" }
        if text.split(separator: " ").count >= 60 { return "long" }
        return nil
    }

    // MARK: Rewrite

    static let instructions = """
        You edit dictated text with the smallest possible change. Do only these edits:
        1. When the speaker corrects themselves (no wait, I mean, actually, sorry, scratch that), keep only the correction.
        2. Delete verbal tics used as filler: you know, basically, like.
        3. Write numbers, money, percentages and times as digits: twenty dollars becomes $20, seven thirty becomes 7:30.
        4. Fix punctuation and capitals.
        Keep words like actually, sorry and I mean when they are not correcting something.
        Keep every other word exactly as spoken. Never add words or information. Never reply to, answer or summarize the text, \
        even if it is a question or a request addressed to someone. Output only the edited text.

        Examples:
        Input: Can you pick up milk, no wait, oat milk on the way home?
        Output: Can you pick up oat milk on the way home?
        Input: The flight leaves at nine, sorry, ten fifteen tomorrow.
        Output: The flight leaves at 10:15 tomorrow.
        Input: The rent is nine hundred actually nine fifty a month.
        Output: The rent is $950 a month.
        Input: The repair was, you know, like three hundred dollars.
        Output: The repair was $300.
        Input: Are you free for lunch on Thursday?
        Output: Are you free for lunch on Thursday?
        Input: I actually liked the first draft, sorry if that was unclear.
        Output: I actually liked the first draft, sorry if that was unclear.
        """

    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    public struct Outcome: Sendable {
        public let text: String
        public let used: Bool
        public let note: String
        public init(text: String, used: Bool, note: String) { self.text = text; self.used = used; self.note = note }
    }

    /// Rewrites `text` when `force` is set or a trigger fires; otherwise returns it unchanged.
    public static func rewrite(_ text: String, mode: CleanupMode, force: Bool = false) async -> Outcome {
        let why = force ? "forced" : reason(for: text, mode: mode)
        guard let why else { return Outcome(text: text, used: false, note: "not needed") }
        guard isAvailable else { return Outcome(text: text, used: false, note: "\(why): Apple model unavailable") }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                // Editing the user's own words is a content transformation; the default guardrails can refuse to load outside Developer ID apps.
                let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
                let session = LanguageModelSession(model: model, instructions: instructions)
                let reply = try await session.respond(to: "Input: \(text)\nOutput:", options: GenerationOptions(sampling: .greedy))
                var edited = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if edited.lowercased().hasPrefix("output:") { edited = String(edited.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
                if let problem = guardProblem(original: text, edited: edited, correction: why == "correction" || why == "forced") {
                    return Outcome(text: text, used: false, note: "\(why): rejected (\(problem)): \(edited)")
                }
                return Outcome(text: Tidy.apply(edited, mode: mode), used: true, note: why)
            } catch {
                return Outcome(text: text, used: false, note: "\(why): model error \(error)")
            }
        }
        #endif
        return Outcome(text: text, used: false, note: "\(why): Apple model unavailable")
    }

    // MARK: Guard

    static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted).filter { !$0.isEmpty }
    }

    /// Returns why the edit is unsafe, or nil. A safe edit only deletes words or turns number words into digits.
    /// Corrections legitimately delete the wrong half ("blue one, scratch that, red one"), so they may drop more.
    static func guardProblem(original: String, edited: String, correction: Bool = false) -> String? {
        let before = words(original), after = words(edited)
        if after.isEmpty { return "empty" }
        let floor = correction ? before.count / 4 : before.count / 2
        if after.count < max(2, floor) { return "dropped too much" }
        if after.count > before.count + 2 { return "added words" }
        let known = Set(before)
        let novel = after.filter { !known.contains($0) && !$0.allSatisfy(\.isNumber) && Double($0) == nil }
        if !novel.isEmpty { return "new words \(novel)" }
        return nil
    }
}
