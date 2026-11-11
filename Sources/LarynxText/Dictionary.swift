import Foundation

/// Your words: "heard this" -> "write that", whole words, any capitalization.
/// Lives in ~/Library/Application Support/Larynx/dictionary.json, e.g. {"lynx": "Larynx", "locust app": "Locust"}.
public enum Dictionary {
    public static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Larynx/dictionary.json")

    public static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return map
    }

    /// Adds or replaces one entry and saves the file.
    public static func add(heard: String, written: String) throws {
        ensureExists()
        var map = load()
        map[heard.lowercased()] = written
        let data = try JSONSerialization.data(withJSONObject: map, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    /// Removes one entry (undoing something learned). Returns false when it wasn't there.
    @discardableResult
    public static func remove(heard: String) throws -> Bool {
        var map = load()
        guard map.removeValue(forKey: heard.lowercased()) != nil else { return false }
        let data = try JSONSerialization.data(withJSONObject: map, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        return true
    }

    /// Creates the file with a starter entry if it doesn't exist yet.
    public static func ensureExists() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("{\n  \"lynx\": \"Larynx\",\n  \"larynx\": \"Larynx\"\n}\n".utf8).write(to: url)
    }

    public static func apply(_ text: String, map: [String: String] = load()) -> String {
        var s = text
        // Longest phrases first so "locust app" wins over "locust".
        for (heard, written) in map.sorted(by: { $0.key.count > $1.key.count }) {
            let pattern = "(?i)\\b" + NSRegularExpression.escapedPattern(for: heard) + "\\b"
            s = s.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: written), options: .regularExpression)
        }
        return s
    }
}
