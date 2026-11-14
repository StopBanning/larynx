import Foundation
import LarynxText

// LarynxText behind JSON, for the Windows app (and anything else that is not Swift). One request runs the same
// cleanup stages, in the same order, as the Mac's Pipeline (snippet, dictionary, tidy, numbers); the Mac's AI
// rewrite and its macOS-only vocabulary-case stage are not here.

private struct Request: Decodable {
    var text: String
    var mode: String?
    var style: String?
    var keepSwearing: Bool?
    var dictionary: [String: String]?
    var snippets: [String: String]?
    /// Which stages to run, for tests ("tidy" alone is what the Swift tests check). Default: all of them.
    var stages: [String]?
}

private struct Response: Encodable {
    var text: String
    var snippet: String?
    var mode: String
}

/// One request: JSON like {"text": "um so", "mode": "correspondence", "dictionary": {...}} in, JSON
/// {"text": "...", "snippet": null, "mode": "..."} out. Bad input gives {"error": "..."}.
public func cleanJSON(_ line: String) -> String {
    guard let req = try? JSONDecoder().decode(Request.self, from: Data(line.utf8)) else {
        return "{\"error\":\"bad request\"}"
    }
    let mode = req.mode.flatMap(CleanupMode.init(rawValue:)) ?? .standard
    let style = req.style.flatMap(Style.init(rawValue:)) ?? .casual
    let stages = Set(req.stages ?? ["snippet", "dictionary", "tidy", "numbers"])
    var out = req.text
    var snippet: String?
    if stages.contains("snippet"), let match = Snippets.match(req.text, in: req.snippets ?? [:]) {
        out = match.text
        snippet = match.cue
    } else {
        if stages.contains("dictionary"), let map = req.dictionary, !map.isEmpty { out = Dictionary.apply(out, map: map) }
        if stages.contains("tidy") { out = Tidy.apply(out, mode: mode, style: style, keepSwearing: req.keepSwearing ?? false) }
        if stages.contains("numbers") { out = Numbers.apply(out) }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let data = (try? encoder.encode(Response(text: out, snippet: snippet, mode: mode.rawValue))) ?? Data()
    // ASCII only on the wire (\u escapes), so no code page on any side can garble it.
    var ascii = ""
    for unit in (String(data: data, encoding: .utf8) ?? "{\"error\":\"encode\"}").utf16 {
        if unit < 0x80 { ascii.unicodeScalars.append(Unicode.Scalar(unit)!) } else { ascii += String(format: "\\u%04x", unit) }
    }
    return ascii
}

/// Loads the word list and compiles the rules once, so the first dictation doesn't pay for it.
public func warmUp() {
    _ = Tidy.apply("um so this is a warm up sentence", mode: .correspondence)
    _ = Numbers.apply("twenty one")
}
