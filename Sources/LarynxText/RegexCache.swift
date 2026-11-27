import Foundation

/// Compiled patterns, built once and reused. Building a pattern costs far more than running it, and the cleanup
/// runs the same few hundred patterns on every dictation.
public enum Rx {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var compiled: [String: NSRegularExpression] = [:]

    /// The same as `try? NSRegularExpression(pattern:options:)`, from the cache after the first time.
    public static func cached(pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = "\(options.rawValue)|\(pattern)"
        if let re = lock.withLock({ compiled[key] }) { return re }
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        lock.withLock {
            if compiled.count >= 4000 { compiled.removeAll() }  // patterns built from your own words stay bounded
            compiled[key] = re
        }
        return re
    }
}

/// `options: .cached` in place of `options: .regularExpression`: the same result, with the pattern from the cache.
struct CachedRegex { static let cached = CachedRegex() }

extension String {
    func replacingOccurrences(of pattern: String, with template: String, options _: CachedRegex) -> String {
        guard let re = Rx.cached(pattern: pattern) else { return self }
        return re.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: template)
    }

    func range(of pattern: String, options _: CachedRegex) -> Range<String.Index>? {
        guard let re = Rx.cached(pattern: pattern),
              let match = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        return Range(match.range, in: self)
    }
}

extension Substring {
    func replacingOccurrences(of pattern: String, with template: String, options: CachedRegex) -> String {
        String(self).replacingOccurrences(of: pattern, with: template, options: options)
    }

    func range(of pattern: String, options _: CachedRegex) -> Range<String.Index>? {
        guard let re = Rx.cached(pattern: pattern) else { return nil }
        let whole = String(self)
        guard let match = re.firstMatch(in: whole, range: NSRange(whole.startIndex..., in: whole)),
              let r = Range(match.range, in: whole) else { return nil }
        let lo = index(startIndex, offsetBy: whole.distance(from: whole.startIndex, to: r.lowerBound))
        return lo..<index(lo, offsetBy: whole.distance(from: r.lowerBound, to: r.upperBound))
    }
}
