import Foundation
import Testing
@testable import LarynxText

// Read the shared cross-platform contract, rather than copying expectations into Swift.
private struct Fixture: Decodable, Sendable {
    let id: String
    let mode: String?
    let input: String
    let expect: String
    let guardCorrection: Bool?
    let guardProblem: String?

    enum CodingKeys: String, CodingKey {
        case id, mode, expect, guardCorrection, guardProblem
        case input = "in"
    }
}

private struct Cases: Decodable {
    let text: [Fixture]
    let rewrite: [Fixture]
    let mustNotChange: [Fixture]

    static func load() throws -> Cases {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Cases.self, from: Data(contentsOf: root.appendingPathComponent("tests/cases.json")))
    }
}

@Test func fixtureContract() throws {
    let cases = try Cases.load()
    #expect(cases.text.count >= 43)
    #expect(cases.rewrite.count >= 26)
    #expect(cases.mustNotChange.count >= 100)
    let all = cases.text + cases.rewrite + cases.mustNotChange
    #expect(Set(all.map(\.id)).count == all.count)
    #expect(Set(cases.mustNotChange.map(\.input)).count == cases.mustNotChange.count)
}

@Test func textRules() throws {
    for c in try Cases.load().text {
        let modeName = try #require(c.mode)
        let mode = try #require(CleanupMode(rawValue: modeName))
        #expect(Tidy.apply(c.input, mode: mode) == c.expect, "\(c.id)")
    }
}

@Test func rewriteGuardExpectations() throws {
    for c in try Cases.load().rewrite {
        let correction = try #require(c.guardCorrection as Bool?)
        #expect(RewriteGuard.guardProblem(original: c.input, edited: c.expect, correction: correction) == c.guardProblem,
                "\(c.id)")
    }
}

@Test func ordinarySentencesStayUnchanged() throws {
    for c in try Cases.load().mustNotChange {
        #expect(c.input == c.expect, "\(c.id): must-not-change fixtures must preserve the input")
        for mode in [CleanupMode.standard, .ai, .correspondence] {
            #expect(Tidy.apply(c.input, mode: mode) == c.expect, "\(c.id), \(mode.rawValue)")
        }
    }
}

// Exercise rejection paths too: accepting every rewrite would pass the golden-output cases.
@Test func unsafeRewritesAreRejected() {
    let original = "Please send the final report to Sam tomorrow."
    #expect(RewriteGuard.guardProblem(original: original, edited: "") == "empty")
    #expect(RewriteGuard.guardProblem(original: original, edited: "Send report.") == "dropped too much")
    #expect(RewriteGuard.guardProblem(original: original, edited: original + " Please send the final report.") == "added words")
    #expect(RewriteGuard.guardProblem(original: original, edited: "Please send the final report to Jenna tomorrow.") == "new words [\"jenna\"]")
    #expect(RewriteGuard.guardProblem(original: "Forward it to Mike, I mean Jenna, before noon.",
                                edited: "Forward it to Mike before noon.", correction: true) == "dropped the correction \"jenna\"")
    #expect(RewriteGuard.guardProblem(original: "Order the blue one. Scratch that, order the red one.",
                                edited: "Order the red one.", correction: true) == nil)
}

@Test func theProfessionalStyleCleansMoreAndCasualIsUntouched() {
    let cases: [(String, String)] = [
        ("Yeah, so we're gonna need the slides by Friday, you know?", "We're going to need the slides by Friday."),
        ("Dude, the new build is so fucking fast, honestly.", "The new build is so fast, honestly."),
        ("Alright, I wanna push the launch, 'cause the venue isn't ready, man.", "I want to push the launch, because the venue isn't ready."),
        ("It's gotta work on the first try.", "It has to work on the first try."),
        ("I mean, it's basically ready, just send it over or whatever.", "It's basically ready, just send it over."),
        ("We still have to sign the lease and stuff you know.", "We still have to sign the lease."),
        ("Oh my god, the client loved it.", "The client loved it."),
        ("Oh yeah, we can ship on Monday.", "We can ship on Monday."),
        ("Number one, book the flights. Number two, book the hotel. And three ask about a rental car.",
         "1. Book the flights\n2. Book the hotel\n3. Ask about a rental car"),
        ("We need two steps before launch: book the venue and print the badges.",
         "We need two steps before launch:\n1. Book the venue\n2. Print the badges"),
    ]
    for (said, written) in cases {
        #expect(Tidy.apply(said, mode: .correspondence, style: .professional) == written, "\(said)")
        // Casual is exactly what Larynx did before the style existed.
        #expect(Tidy.apply(said, mode: .correspondence, style: .casual) == Tidy.apply(said, mode: .correspondence))
    }
    // What must not change, found by reading the rules against real dictation.
    for kept in ["So far the numbers look fine.", "So much for the plan.", "They kept fucking the order up.", "Stop fucking around with it.",
                 "The cause of the delay is known.", "Yeah.", "I mean it when I say thanks.",
                 "It means more than you know."] {
        #expect(Tidy.apply(kept, mode: .correspondence, style: .professional) == kept, "\(kept)")
    }
    // Swearing can be kept.
    #expect(Tidy.apply("It was damn good.", mode: .correspondence, style: .professional, keepSwearing: true) == "It was damn good.")
    #expect(Tidy.apply("It was damn good.", mode: .correspondence, style: .professional) == "It was good.")
}

@Test func daysOfTheWeekAreCapitalizedOutsideTheAIMode() {
    #expect(Tidy.apply("the review moved to friday", mode: .correspondence) == "The review moved to Friday.")
    #expect(Tidy.apply("we meet on mondays and thursdays", mode: .standard) == "We meet on Mondays and Thursdays")
    // In the AI mode the text may be code, and in paths, flags and identifiers a day is not a name.
    #expect(Tidy.apply("rename friday_report to monday", mode: .ai).contains("friday_report"))
    #expect(Tidy.apply("open reports/friday.csv", mode: .standard).contains("reports/friday.csv"))
}

@Test func theProfessionalStyleDropsFillerLikeSwearOpenersAndRestarts() {
    func pro(_ s: String) -> String { Tidy.apply(s, mode: .ai, style: .professional) }
    #expect(pro("Like most of the tickets are gone already") == "Most of the tickets are gone already")
    #expect(pro("The draft is fine, but like it needs a stronger ending") == "The draft is fine, but it needs a stronger ending")
    #expect(pro("We sat with them in like the back row") == "We sat with them in the back row")
    #expect(pro("Oh shit, I left the charger at home") == "I left the charger at home")
    #expect(pro("There's two files missing from the folder") == "There are two files missing from the folder")
    // Kept: "like" as a verb or a comparison, and casual is unchanged.
    #expect(pro("Like her, I would rather wait") == "Like her, I would rather wait")
    #expect(pro("I like the new layout") == "I like the new layout")
    #expect(pro("It looks like the build passed") == "It looks like the build passed")
    #expect(Tidy.apply("Oh shit, I left the charger at home", mode: .ai) == "Oh shit, I left the charger at home")
}

@Test func aRestartAfterGoingToBeAndANumberRangeAreCleanedInEveryStyle() {
    #expect(Tidy.apply("We're going to be we're stuck in traffic", mode: .ai) == "We're stuck in traffic")
    #expect(Tidy.apply("The bus comes in 10 15 minutes", mode: .ai) == "The bus comes in 10 to 15 minutes")
    #expect(Tidy.apply("Room 20 10 people fit", mode: .ai).contains("20 10 people"))  // the second is smaller: not a range
}

@Test func spokenCorrectionsKeepWhatWasMeant() {
    func t(_ s: String) -> String { Tidy.apply(s, mode: .correspondence) }
    #expect(t("Forward it to Ellen, no, forward it to Marcus") == "Forward it to Marcus.")
    #expect(t("The talk begins at nine, sorry, at ten") == "The talk begins at ten.")
    #expect(t("Order pizza for three, I mean four people") == "Order pizza for four people.")
    #expect(t("We fly out Friday, no wait, Saturday night") == "We fly out Saturday night.")
    #expect(t("Park near the, actually park behind the gym") == "Park behind the gym.")
    // An answer, not a correction: nothing said earlier is restarted, so it stays.
    #expect(t("I asked if she was coming and no, she can't make it") == "I asked if she was coming and no, she can't make it.")
}

@Test func aWordSaidTwiceIsAStutterUnlessTheDoubleIsMeant() {
    func t(_ s: String) -> String { Tidy.apply(s, mode: .correspondence) }
    #expect(t("Could you print print the boarding passes") == "Could you print the boarding passes.")
    #expect(t("I think that that plan works") == "I think that that plan works.")
    #expect(t("The cake was really really good") == "The cake was really really good.")
    #expect(t("It's not not ready") == "It's not not ready.")
    #expect(t("Knock knock, who's there") == "Knock knock, who's there.")
    #expect(t("Bang bang bang went the drums") == "Bang bang bang went the drums.")
}

@Test func theProfessionalStyleDropsIMeanAsAFiller() {
    func pro(_ s: String) -> String { Tidy.apply(s, mode: .ai, style: .professional) }
    #expect(pro("The draft is done. Is I mean because the client asked early") == "The draft is done. Because the client asked early")
    #expect(pro("It compiles, I mean the warnings are gone") == "It compiles, the warnings are gone")
    #expect(pro("Yet I mean the plan holds up") == "Yet the plan holds up")
    #expect(pro("I mean it, no more delays") == "I mean it, no more delays")
    #expect(pro("What I mean is we wait") == "What I mean is we wait")
}
