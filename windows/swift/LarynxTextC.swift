import Foundation
import LarynxText

// A C door into LarynxText for the Windows app (and anything else that is not Swift). One call runs the same
// cleanup stages, in the same order, as the Mac's Pipeline (snippet, dictionary, tidy, numbers); the Mac's AI
// rewrite and its macOS-only vocabulary-case stage are not here. Strings are UTF-8 and JSON; every string this
// library returns must be handed back to `larynx_free`.

private struct Options: Decodable {
    var mode: String?
    var style: String?
    var keepSwearing: Bool?
    var dictionary: [String: String]?
    var snippets: [String: String]?
    /// Which stages to run, for tests ("tidy" alone is what the Swift tests check). Default: all of them.
    var stages: [String]?
}

private struct Result: Encodable {
    var text: String
    var snippet: String?
    var mode: String
}

private func cString(_ s: String) -> UnsafeMutablePointer<CChar> {
    let bytes = Array(s.utf8CString)
    let p = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
    p.initialize(from: bytes, count: bytes.count)
    return p
}

/// Cleans dictated text. `options` is JSON like {"mode": "correspondence", "style": "casual", "dictionary": {...}}.
/// Returns JSON {"text": "...", "snippet": "cue or null", "mode": "..."}.
@_cdecl("larynx_clean")
public func larynx_clean(_ text: UnsafePointer<CChar>?, _ options: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    let input = text.map { String(cString: $0) } ?? ""
    let opts = options.flatMap { try? JSONDecoder().decode(Options.self, from: Data(String(cString: $0).utf8)) } ?? Options()
    let mode = opts.mode.flatMap(CleanupMode.init(rawValue:)) ?? .standard
    let style = opts.style.flatMap(Style.init(rawValue:)) ?? .casual
    let stages = Set(opts.stages ?? ["snippet", "dictionary", "tidy", "numbers"])
    var out = input
    var snippet: String?
    if stages.contains("snippet"), let match = Snippets.match(input, in: opts.snippets ?? [:]) {
        out = match.text
        snippet = match.cue
    } else {
        if stages.contains("dictionary"), let map = opts.dictionary, !map.isEmpty { out = Dictionary.apply(out, map: map) }
        if stages.contains("tidy") { out = Tidy.apply(out, mode: mode, style: style, keepSwearing: opts.keepSwearing ?? false) }
        if stages.contains("numbers") { out = Numbers.apply(out) }
    }
    let result = Result(text: out, snippet: snippet, mode: mode.rawValue)
    let json = (try? JSONEncoder().encode(result)).flatMap { String(data: $0, encoding: .utf8) } ?? "{\"text\":\"\"}"
    return cString(json)
}

@_cdecl("larynx_free")
public func larynx_free(_ p: UnsafeMutablePointer<CChar>?) {
    p?.deallocate()
}

/// Loads the word list and compiles the rules once, so the first dictation doesn't pay for it.
@_cdecl("larynx_warm")
public func larynx_warm() {
    _ = Tidy.apply("um so this is a warm up sentence", mode: .correspondence)
    _ = Numbers.apply("twenty one")
}
