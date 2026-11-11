import Testing
@testable import LarynxText

private let english: Set<String> = ["can", "are", "and", "then", "we", "compact", "let", "me", "come", "back", "fable", "the"]
private func fit(_ text: String, _ before: String?, selection: Bool = false) -> String {
    Fit.adjust(text, before: before, replacingSelection: selection, keepsCapital: { ["Opus", "Fable"].contains($0) },
               isEnglish: { english.contains($0) })
}

@Test func aNewSentenceAfterOneThatEndedGetsItsSpace() {
    #expect(fit("Are we ready?", "I don't recall the time.") == " Are we ready?")
    #expect(fit("And then let me come back.", "do we have to right now?") == " And then let me come back.")
    #expect(fit("Compact.", "come back. ") == "Compact.")          // already a space
}

@Test func midSentenceTheCapitalGoesAndASpaceIsAdded() {
    #expect(fit("Can you send it?", "Hey Sam,") == " can you send it?")
    #expect(fit("I think so.", "Well,") == " I think so.")          // "I" keeps its capital
    #expect(fit("Opus can do it.", "Then") == " Opus can do it.")    // a term keeps its capital
    #expect(fit("Priya can do it.", "Ask whether") == " Priya can do it.")  // not an English word: a name
    #expect(fit("API keys rotate.", "the") == " API keys rotate.")
}

@Test func emptyNewLineSelectionAndUnreadableFieldsAreLeftAlone() {
    #expect(fit("Are we ready?", nil) == "Are we ready?")
    #expect(fit("Are we ready?", "") == "Are we ready?")
    #expect(fit("Are we ready?", "Hello\n") == "Are we ready?")
    #expect(fit("Are we ready?", "time.", selection: true) == "Are we ready?")
    #expect(fit("Are we ready?", "Email: (") == "Are we ready?")   // after an opening bracket, no space
    #expect(fit(", and more.", "apples") == ", and more.")        // starts with punctuation, no space
}
