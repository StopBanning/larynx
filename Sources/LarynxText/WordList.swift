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
        words = Set(text.split(separator: "\n").map { String($0).lowercased() })
    }

    public func contains(_ word: String) -> Bool { words.contains(word.lowercased()) }
    public var count: Int { words.count }
}
