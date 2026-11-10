import AppKit
import ApplicationServices

/// Learns words from your fixes: shortly after a paste, it reads the text field again. If you changed a word or two
/// to something that sounds like what was heard ("Gavy" -> "Govee"), the new word goes into your vocabulary (and,
/// when the heard word isn't real English, into the dictionary too), so it comes out right next time.
public enum Learner {
    /// The text field that has focus in `app`, to read again later. Nil for password fields and non-text elements.
    public static func focusedTextElement(in app: NSRunningApplication?) -> AXUIElement? {
        guard Inserter.isTrusted, let app else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        if (role as? String) == "AXSecureTextField" || (subrole as? String) == "AXSecureTextField" { return nil }
        return text(of: element) == nil ? nil : element
    }

    public static func text(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
    }

    /// Words the user changed in what was pasted: (heard, fixed) pairs that sound alike. Empty when the text was left
    /// alone, rewritten heavily, or can't be found.
    public static func fixes(pasted: String, now: String) -> [(heard: String, fixed: String)] {
        let p = tokens(pasted), v = tokens(now)
        guard p.count >= 3, v.count >= p.count else { return [] }
        var best: (start: Int, misses: Int) = (0, .max)
        for start in 0...(v.count - p.count) {
            var misses = 0
            for k in 0..<p.count where p[k] != v[start + k] {
                misses += 1
                if misses >= best.misses { break }
            }
            if misses < best.misses { best = (start, misses) }
            if misses == 0 { return [] }  // found unchanged
        }
        guard best.misses >= 1, best.misses <= 2, best.misses * 3 <= p.count else { return [] }
        var out: [(String, String)] = []
        for k in 0..<p.count {
            let heard = p[k], fixed = v[best.start + k]
            guard heard != fixed, fixed.count >= 3, fixed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
                  heard.lowercased() == fixed.lowercased() || Transcriber.soundsAlike(heard, fixed) else { continue }
            out.append((heard, fixed))
        }
        return out
    }

    /// Saves what was learned. Returns the words that were new.
    @discardableResult
    public static func learn(_ fixes: [(heard: String, fixed: String)]) -> [String] {
        Vocabulary.ensureExists()
        var file = (try? String(contentsOf: Vocabulary.url, encoding: .utf8)) ?? ""
        let known = Set(file.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        var added: [String] = []
        for (heard, fixed) in fixes {
            if !known.contains(fixed.lowercased()), !added.contains(fixed) {
                if !file.hasSuffix("\n"), !file.isEmpty { file += "\n" }
                file += fixed + "\n"
                added.append(fixed)
            }
            // A made-up word the speech model produced ("Gavy") can safely always become the fix.
            if heard.lowercased() != fixed.lowercased(), !Vocabulary.isEnglish(heard) {
                try? Dictionary.add(heard: heard, written: fixed)
            }
        }
        if !added.isEmpty { try? file.write(to: Vocabulary.url, atomically: true, encoding: .utf8) }
        return added
    }
}
