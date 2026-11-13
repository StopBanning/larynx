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
        ("Oh my god, the client loved it.", "The client loved it."),
        ("Oh yeah, we can ship on Monday.", "We can ship on Monday."),
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
                 "The cause of the delay is known.", "Yeah.", "I mean it when I say thanks."] {
        #expect(Tidy.apply(kept, mode: .correspondence, style: .professional) == kept, "\(kept)")
    }
    // Swearing can be kept.
    #expect(Tidy.apply("It was damn good.", mode: .correspondence, style: .professional, keepSwearing: true) == "It was damn good.")
    #expect(Tidy.apply("It was damn good.", mode: .correspondence, style: .professional) == "It was good.")
}
