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

/// The professional style removes more ("Yeah," openers, swearing), but never a "like" that is a verb, a comparison or
/// a set phrase ("Like I said", "like it or not", "and like that, it was gone").
@Test func theProfessionalStyleKeepsEveryMeaningfulLike() throws {
    for c in try Cases.load().mustNotChange where c.input.lowercased().contains("like") {
        #expect(Tidy.apply(c.input, mode: .ai, style: .professional).contains("like") || Tidy.apply(c.input, mode: .ai, style: .professional).contains("Like"),
                "\(c.id): professional dropped a meaningful like")
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
    #expect(t("Can we push the review to Monday No, wait, Tuesday?") == "Can we push the review to Tuesday?")
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

@Test func aCutOffWordWrittenWithAHyphenGoes() {
    #expect(Tidy.apply("Ask the design team. Th- okay, just check with them", mode: .ai) == "Ask the design team. Okay, just check with them")
    #expect(Tidy.apply("It covers pre- and post-launch work", mode: .ai) == "It covers pre- and post-launch work")
    #expect(Tidy.apply("Send the e-mail and the x-ray", mode: .ai) == "Send the e-mail and the x-ray")
}

@Test func youYouKnowKeepsBothYous() {
    // "you know" as a filler goes in every mode (Nov 19), and the "you" it follows stays.
    #expect(Tidy.apply("Nobody told you, you know, that the shop moved", mode: .correspondence) == "Nobody told you that the shop moved.")
    #expect(Tidy.apply("Nobody told you, you know, that the shop moved", mode: .ai) == "Nobody told you that the shop moved")
    #expect(Tidy.apply("Did you you finish the report", mode: .ai) == "Did you finish the report")
}

@Test func theAIModeCleansNoiseButKeepsTheSpeakersVoice() {
    func ai(_ s: String) -> String { Tidy.apply(s, mode: .ai) }
    // Noise goes: discourse fillers carry nothing a model needs.
    #expect(ai("Can you, you know, rerun the migration") == "Can you rerun the migration")
    #expect(ai("I mean the schema looks wrong") == "The schema looks wrong")
    #expect(ai("Like I think the cache is stale") == "I think the cache is stale")
    // Voice stays: answers, forms of address, swearing and spoken forms are how the speaker talks.
    #expect(ai("Yeah, ship it") == "Yeah, ship it")
    #expect(ai("Nice work, buddy") == "Nice work, buddy")
    #expect(ai("We're gonna fix this damn bug") == "We're gonna fix this damn bug")
}

@Test func theTextingStyleWritesLikeAText() {
    func text(_ s: String) -> String { Tidy.apply(s, mode: .correspondence, style: .texting) }
    #expect(text("sounds good, see you at 7") == "sounds good, see you at 7")
    #expect(text("Are you free for lunch tomorrow? Let's do 12.") == "are you free for lunch tomorrow? let's do 12")
    #expect(text("I can't make it. Dana can though.") == "I can't make it. Dana can though")  // "I" and names keep capitals
    #expect(text("NASA called back. Wow!") == "NASA called back. wow!")                     // acronyms and "!" stay
    #expect(text("Mark is here. Ask Mark.") == "Mark is here. ask Mark")                     // a word capitalized mid-sentence is a name
    #expect(Tidy.apply("See you Friday.", mode: .correspondence, style: .casual) == "See you Friday.")  // casual untouched
}

@Test func stutterRestartsInsideAWordAreCleaned() {
    func ai(_ s: String) -> String { Tidy.apply(s, mode: .ai) }
    #expect(ai("Could th could we move the call?") == "Could we move the call?")          // word, fragment, word
    #expect(ai("Please book it for the conf for the conference room.") == "Please book it for the conference room.")
    #expect(ai("We pr probably need more chairs.") == "We probably need more chairs.")    // fragment, then its word
    #expect(ai("Can we st start at noon?") == "Can we start at noon?")
    #expect(ai("We walked in into the hall.") == "We walked in into the hall.")           // "in" is a word: kept
    #expect(ai("Bam bam bam, here we go.") == "Bam bam bam, here we go.")                 // a chant is not a stutter
    #expect(ai("Go with plan b because it's cheaper.") == "Go with plan b because it's cheaper.")
    #expect(ai("Bring snacks that k kids like.") == "Bring snacks that kids like.")      // a lone letter, then its word
    #expect(ai("It took nearly t ten minutes.") == "It took nearly ten minutes.")
    #expect(ai("Write the c code first.") == "Write the c code first.")                   // after "the": a label
    #expect(ai("Take vitamin d daily.") == "Take vitamin d daily.")
    #expect(ai("I ate a apple.") == "I ate a apple.")                                     // "a" is a word
}

@Test func aRestartWithAPronounRepeatsTheVerb() {
    func ai(_ s: String) -> String { Tidy.apply(s, mode: .ai) }
    #expect(ai("The bakery closes at six. No, it closes at five on Mondays.") == "The bakery closes at five on Mondays.")
    #expect(ai("The bus leaves at noon, sorry, it leaves at one.") == "The bus leaves at one.")
    #expect(ai("Is the pool open at eight? No, it opens at nine.") == "Is the pool open at eight? No, it opens at nine.")  // an answer
    #expect(ai("The fridge is old. No, it works fine.") == "The fridge is old. No, it works fine.")                // no repeated verb
    #expect(ai("Ham, the porch light is out again.") == "The porch light is out again.")
}

@Test func loneLetterStumblesGo() {
    func c(_ s: String) -> String { Tidy.apply(s, mode: .correspondence) }
    #expect(c("Maybe b as b biking is faster.") == "Maybe biking is faster.")
    #expect(c("Give h as half the cake to Sam.") == "Give half the cake to Sam.")
    #expect(c("She walked o over to the shop.") == "She walked over to the shop.")
    #expect(c("Sure, we w we can leave now.") == "Sure, we can leave now.")
    #expect(c("Keep plan b as backup.") == "Keep plan b as backup.")                  // a label
    #expect(c("Take vitamin d daily.") == "Take vitamin d daily.")
}

@Test func familyNamesGetACapitalWhenSpokenTo() {
    func c(_ s: String) -> String { Tidy.apply(s, mode: .correspondence) }
    #expect(c("Hey dad, the parcel came today.") == "Hey Dad, the parcel came today.")
    #expect(c("Thanks mom for the soup.") == "Thanks Mom for the soup.")
    #expect(c("The train was quick, dad.") == "The train was quick, Dad.")
    #expect(c("Love you grandma.") == "Love you Grandma.")
    #expect(c("My dad fixed the fence.") == "My dad fixed the fence.")                // not a name here
    #expect(c("We visited your mom on Sunday.") == "We visited your mom on Sunday.")
    #expect(c("I called my sister, mom and the plumber.") == "I called my sister, mom and the plumber.")
    #expect(Tidy.apply("hey dad", mode: .ai) == "Hey dad")                         // AI mode leaves it
}

@Test func prepositionEndingAPhraseKeepsItsComma() {
    func c(_ s: String) -> String { Tidy.apply(s, mode: .correspondence) }
    #expect(c("Ask them what they argued about, without raising your voice.") == "Ask them what they argued about, without raising your voice.")
    #expect(c("That's the friend I came with, and her sister came too.") == "That's the friend I came with, and her sister came too.")
    #expect(c("Let's meet at, um, the library.") == "Let's meet at the library.")             // a filler's leftover comma still goes
}

@Test func fillerYouKnowGoesInEveryStyle() {
    func c(_ s: String) -> String { Tidy.apply(s, mode: .correspondence) }
    #expect(c("The soup was, you know, a bit cold.") == "The soup was a bit cold.")
    #expect(c("Keep sanding, you know, we can paint tomorrow.") == "Keep sanding, we can paint tomorrow.")  // two thoughts
    #expect(c("But you know, our bus was late.") == "But our bus was late.")
    #expect(c("You know, the garden needs rain.") == "The garden needs rain.")
    #expect(c("It's you know, it's a long walk.") == "It's a long walk.")
    #expect(c("We should leave early, you know?") == "We should leave early.")
    #expect(c("If you know, tell me.") == "If you know, tell me.")                                   // the verb
    #expect(c("The neighbors that you know, they moved.") == "The neighbors that you know, they moved.")
    #expect(c("As you know, the shop closes at six.") == "As you know, the shop closes at six.")
    #expect(c("I bet you know, the answer is no.") == "I bet you know, the answer is no.")
    #expect(c("Just so you know he called.") == "Just so you know he called.")                       // no comma after
    #expect(c("You know what she said.") == "You know what she said.")
    #expect(c("Everybody who has has a ticket.") == "Everybody who has has a ticket.")               // meant double
}

@Test func professionalDropsAnOpeningWell() {
    func p(_ s: String) -> String { Tidy.apply(s, mode: .correspondence, style: .professional) }
    #expect(p("Well, the meeting moved to Friday.") == "The meeting moved to Friday.")
    #expect(p("Well we can try again tomorrow.") == "We can try again tomorrow.")
    #expect(p("Well done on the launch.") == "Well done on the launch.")
    #expect(p("Well over half of them replied.") == "Well over half of them replied.")
    #expect(Tidy.apply("Well, the meeting moved to Friday.", mode: .correspondence) == "Well, the meeting moved to Friday.")  // casual keeps it
}

@Test func strongStutterCleanupOnlyWhenTurnedOn() {
    func n(_ s: String) -> String { Tidy.apply(s, mode: .correspondence) }
    func strong(_ s: String) -> String { Tidy.apply(s, mode: .correspondence, stutter: .strong) }
    // A cut-off word said twice, never finished, and a two-word phrase said twice.
    #expect(strong("We are packing and cle uh to cle to leave soon.") == "We are packing and to leave soon.")
    #expect(strong("Ride on a on a bike.") == "Ride on a bike.")
    #expect(strong("She sent it she sent it twice.") == "She sent it twice.")
    // The standard rules leave them.
    #expect(n("We are packing and cle uh to cle to leave soon.") == "We are packing and cle to cle to leave soon.")
    // Meant repeats stay, even when strong.
    #expect(strong("Row row row row your boat.") == "Row row row row your boat.")
    #expect(strong("We had had enough.") == "We had had enough.")
    #expect(strong("Bye bye now.") == "Bye bye now.")
}

@Test func phraseRestartedAroundYouKnowKeepsOneCopy() {
    func c(_ s: String) -> String { Tidy.apply(s, mode: .correspondence) }
    #expect(c("Most days the bus is you know, most days the bus is late.") == "Most days the bus is late.")
    #expect(c("She can, you know, she can paint it blue.") == "She can paint it blue.")
    #expect(c("It was you know, fine.") == "It was fine.")
}

@Test func strongStutterKeepsAndRepeats() {
    #expect(Tidy.apply("She knocks and knocks and knocks.", mode: .correspondence, stutter: .strong) == "She knocks and knocks and knocks.")
}
