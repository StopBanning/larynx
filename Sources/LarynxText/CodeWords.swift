import Foundation

/// Spoken code: "camel case user id" -> userId, "snake case max retries" -> max_retries, "main dot swift" -> main.swift,
/// "json" -> JSON. Rules only, so it's instant and exact.
public enum CodeWords {
    static let caseCommands: [(spoken: String, style: String)] = [
        ("screaming snake case", "constant"), ("constant case", "constant"), ("all caps", "constant"),
        ("camel case", "camel"), ("camelcase", "camel"), ("pascal case", "pascal"), ("snake case", "snake"),
        ("kebab case", "kebab"), ("dash case", "kebab"),
    ]
    /// Words that end a cased name: "camel case user id to account id" -> "userId to account id".
    static let stopWords: Set<String> = ["the", "a", "an", "to", "and", "or", "in", "into", "on", "for", "with", "from", "is",
        "as", "at", "of", "by", "then", "so", "but", "that", "which", "it", "instead", "please",
        // what the name is: "a snake case max retries constant" -> "a max_retries constant"
        "constant", "variable", "var", "function", "method", "class", "struct", "enum", "file", "field", "property",
        "component", "column", "table", "parameter", "param", "argument", "hook", "module", "type", "flag", "folder"]
    static let extensions = "swift|ts|tsx|js|jsx|mjs|py|md|json|yaml|yml|toml|html|css|scss|rs|go|rb|java|kt|sh|txt|sql|lock|plist|xml|csv|com|io|ai|dev|app|org|net"
    static let acronyms: [String: String] = [
        "api": "API", "apis": "APIs", "json": "JSON", "url": "URL", "urls": "URLs", "html": "HTML", "css": "CSS", "sql": "SQL",
        "sdk": "SDK", "sdks": "SDKs", "cli": "CLI", "ssh": "SSH", "http": "HTTP", "https": "HTTPS", "jwt": "JWT", "cpu": "CPU",
        "gpu": "GPU", "aws": "AWS", "gcp": "GCP", "ui": "UI", "ux": "UX", "ios": "iOS", "macos": "macOS", "npm": "npm",
        "yaml": "YAML", "csv": "CSV", "pdf": "PDF", "llm": "LLM", "llms": "LLMs", "mcp": "MCP", "oauth": "OAuth",
        "github": "GitHub", "gitlab": "GitLab", "javascript": "JavaScript", "typescript": "TypeScript", "graphql": "GraphQL",
        "postgres": "Postgres", "postgresql": "PostgreSQL", "mysql": "MySQL", "sqlite": "SQLite", "mongodb": "MongoDB",
        "swiftui": "SwiftUI", "xcode": "Xcode", "vscode": "VS Code", "pr": "PR", "prs": "PRs", "ci": "CI", "dns": "DNS",
        "tcp": "TCP", "udp": "UDP", "ip": "IP", "ram": "RAM", "ssd": "SSD", "uuid": "UUID", "regex": "regex",
    ]

    public static func apply(_ text: String) -> String {
        var s = joinSpelledLetters(applyCaseCommands(text))
        // "main dot swift" -> main.swift, "example dot com" -> example.com, "dot env" -> .env
        s = s.replacingOccurrences(of: "(?i)\\b(?!(?:the|a|an|and|or|to|of|in|on|at|for|with|is|my|your|our)\\b)([A-Za-z0-9_\\-]+)\\s+dot\\s+(\(extensions))\\b", with: "$1.$2", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)(^|\\s)dot\\s+(env|gitignore|zshrc|bashrc)\\b", with: "$1.$2", options: .regularExpression)
        // Acronyms and product spellings, whole words only.
        for (spoken, written) in acronyms {
            s = s.replacingOccurrences(of: "(?i)(?<![\\w.])\(spoken)(?![\\w])", with: written, options: .regularExpression)
        }
        return s
    }

    /// Two-letter acronyms the speech model spells out ("U I" -> UI). "A I" is left alone: "plan A I think" is common.
    static let letterPairs: Set<String> = ["UI", "UX", "ML", "PR", "OS", "ID", "QA", "CI", "CD", "DM", "TV", "VM", "DB", "PC",
                                           "MD", "QR", "PE", "AR", "VR", "HR"]

    /// Spelled-out capitals become one acronym: "A P I" -> API, "T. S. M." -> TSM, "U R L" -> URL.
    /// Three letters or more, or a known pair; single letters elsewhere ("plan A", "I think") are untouched.
    static func joinSpelledLetters(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "(?<![\\w.])(?:[a-z]\\. (?=[A-Z]\\.))?(?:[A-Z]\\.? ){1,5}[A-Z](?:\\.(?=\\s+[a-z]))?(?![\\w])") else { return s }
        var out = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(m.range, in: out) else { continue }
            let letters = out[r].filter(\.isLetter).uppercased()
            guard letters.count >= 3 || letterPairs.contains(String(letters)) else { continue }
            out.replaceSubrange(r, with: String(letters))
        }
        return out
    }

    static func applyCaseCommands(_ text: String) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i < words.count {
            var matched: (count: Int, style: String)?
            for (spoken, style) in caseCommands {
                let parts = spoken.split(separator: " ").map(String.init)
                guard i + parts.count <= words.count else { continue }
                let said = words[i..<(i + parts.count)].map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
                if said == parts { matched = (parts.count, style); break }
            }
            guard let (count, style) = matched else { i += 1; continue }
            // Gather the name: up to 6 words, stopping at a small word or after a word that ends in punctuation.
            var j = i + count, name: [String] = [], trailing = ""
            while j < words.count, name.count < 6 {
                let raw = words[j]
                let core = raw.trimmingCharacters(in: .punctuationCharacters)
                if core.isEmpty || (stopWords.contains(core.lowercased()) && !name.isEmpty) { break }
                name.append(core.lowercased())
                j += 1
                if raw != core, let last = raw.last, ",.!?;:".contains(last) { trailing = String(last); break }
            }
            guard !name.isEmpty else { i += 1; continue }
            let joined: String
            switch style {
            case "camel": joined = name[0] + name.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
            case "pascal": joined = name.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
            case "snake": joined = name.joined(separator: "_")
            case "kebab": joined = name.joined(separator: "-")
            default: joined = name.joined(separator: "_").uppercased()
            }
            words.replaceSubrange(i..<j, with: [joined + trailing])
            i += 1
        }
        return words.joined(separator: " ")
    }
}
