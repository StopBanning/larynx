import Foundation
import Testing
@testable import LarynxText

private struct NumberCases: Decodable {
    struct Change: Decodable { let `in`: String; let expect: String }
    let change: [Change]
    let keep: [String]
    static func load() throws -> NumberCases {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        struct File: Decodable { let numbers: NumberCases }
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: root.appendingPathComponent("tests/cases.json"))).numbers
    }
}

@Test func spokenNumbersBecomeDigits() throws {
    for c in try NumberCases.load().change {
        #expect(Numbers.apply(c.in) == c.expect, "\(c.in)")
    }
}

@Test func ordinaryWordsAreNeverTurnedIntoNumbers() throws {
    for s in try NumberCases.load().keep {
        #expect(Numbers.apply(s) == s, "\(s)")
    }
}
