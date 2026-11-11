import Foundation

/// Voice shortcuts: say a cue on its own ("my calendar link") and Larynx types the full text instead.
/// Stored in `~/Library/Application Support/Larynx/snippets.json` as {"cue": "text to type"}.
public enum Snippets {
    public static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Larynx/snippets.json")

    public static func ensureExists() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("""
            {
              "larynx repo": "https://github.com/StopBanning/larynx"
            }

            """.utf8).write(to: url)
    }

    public static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return map
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The snippet text when the whole utterance is a cue (punctuation and capitals ignored; "snippet" or "insert"
    /// in front is allowed), else nil.
    public static func match(_ spoken: String, in map: [String: String] = load()) -> (cue: String, text: String)? {
        var said = normalize(spoken)
        for prefix in ["snippet ", "insert ", "paste "] where said.hasPrefix(prefix) { said.removeFirst(prefix.count) }
        guard !said.isEmpty else { return nil }
        for (cue, text) in map where normalize(cue) == said { return (cue, text) }
        return nil
    }

    public static func add(cue: String, text: String) throws {
        ensureExists()
        var map = load()
        map[cue] = text
        try JSONSerialization.data(withJSONObject: map, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}
