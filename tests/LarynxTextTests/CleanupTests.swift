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
