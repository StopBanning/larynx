import Foundation

/// A spelling policy supplied by the host; the text target never imports platform UI frameworks.
public protocol WordList {
    func contains(_ word: String) -> Bool
}

/// Portable English fallback. Exact, case-insensitive lookup; no stemming or guessed words.
public struct BundledWordList: WordList {
    public static let shared = BundledWordList()
    private let words: Set<String>

    public init() {
        guard let url = Bundle.module.url(forResource: "english", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("LarynxText's bundled English word list is missing or unreadable")
        }
        // Any line ending: Windows checkouts turn "\n" into "\r\n", which Swift treats as one Character.
        words = Set(text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
    }

    public func contains(_ word: String) -> Bool { words.contains(word.lowercased()) }
    public var count: Int { words.count }
}
