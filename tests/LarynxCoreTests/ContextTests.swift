import Testing
@testable import LarynxCore
@testable import LarynxText

@Test func homophonesTakeTheSpellingOnScreenOnlyWhereANounFits() {
    #expect(ContextWords.phoneticKey("Dock") == ContextWords.phoneticKey("doc"))
    #expect(ContextWords.phoneticKey("Claude") == ContextWords.phoneticKey("clod"))
    #expect(ContextWords.proposal("Ask the clod to draft the summary.", screenTerms: ["Claude", "Settings"])
            == "Ask the Claude to draft the summary.")
    #expect(ContextWords.proposal("Pin the app to the doc on the left.", screenTerms: ["Dock"]) == "Pin the app to the Dock on the left.")
    #expect(ContextWords.proposal("Can we make it so the button works?", screenTerms: ["Mac"]) == nil)       // a verb
    #expect(ContextWords.proposal("That is the real reason.", screenTerms: ["Reel"]) == nil)               // an adjective
    #expect(ContextWords.proposal("The rust on the bike is bad.", screenTerms: ["Russ"]) == nil)           // doesn't sound the same
    #expect(ContextWords.proposal("Send the doc today.", screenTerms: []) == nil)
}

@Test func screenTermsAreNamesIdentifiersAndUnknownWordsButNotLabels() {
    let english: Set<String> = ["right", "click", "the", "and", "choose", "options", "open", "settings", "shows", "dock"]
    let terms = ContextTerms.extract(["Settings\nRight-click the Dock and choose Options.\nOpen main.swift and fooBar today"],
                                     isEnglish: { english.contains($0) })
    #expect(terms.contains("Dock") && terms.contains("Options") && terms.contains("main.swift") && terms.contains("fooBar"))
    #expect(!terms.contains("Settings"))   // a one-word line: an interface label
}
