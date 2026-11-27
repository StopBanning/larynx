import Foundation
import Testing
@testable import LarynxText

/// The cleanup builds each pattern once and reuses it. The result must be exactly what Foundation gives.
@Test func cachedPatternsMatchFoundation() {
    let texts = ["Can you, um, send me the the slides by Tuesday?", "", "ünïcode café, naïve résumé 😀 ok", "a\nb\n\nc", "x x x"]
    let patterns: [(String, String)] = [("(?i)\\bthe\\s+the\\b", "the"), ("([,.])\\s+", "$1 "), ("^\\s*(\\w)", "[$1]"),
                                        ("(?<![\\w'])x(?![\\w'])", "y"), ("\\n{2,}", "\\\\n"), ("é", "e")]
    for text in texts {
        for (pattern, template) in patterns {
            for _ in 0..<2 {  // the second time comes from the cache
                #expect(text.replacingOccurrences(of: pattern, with: template, options: .cached)
                        == text.replacingOccurrences(of: pattern, with: template, options: .regularExpression))
                #expect(text.range(of: pattern, options: .cached) == text.range(of: pattern, options: .regularExpression))
                let sub = text.dropFirst(min(2, text.count))
                #expect(sub.range(of: pattern, options: .cached) == sub.range(of: pattern, options: .regularExpression))
            }
        }
    }
    #expect(Rx.cached(pattern: "(") == nil)
}
