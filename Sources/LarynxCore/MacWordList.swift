import AppKit
import LarynxText

/// Preserve macOS's existing spelling decisions, including the user's learned words.
public struct MacWordList: WordList {
    public init() {}

    public func contains(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: word.lowercased(), startingAt: 0, language: "en", wrap: false,
                                            inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }
}
