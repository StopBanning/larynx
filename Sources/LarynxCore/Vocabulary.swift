import AppKit

/// Words the speech model should listen for: your project names, your dictionary, and anything you add to
/// `~/Library/Application Support/Larynx/vocabulary.txt` (one word or phrase per line, `#` for comments).
/// After each transcript, a small keyword model checks the audio for these words and swaps them in where they fit.
public enum Vocabulary {
    public static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Larynx/vocabulary.txt")
    /// Where project names are learned from: `defaults write com.automatedworkflow.larynx vocabularyRoots ~/work,~/code`.
    public static var roots: [URL] {
        let saved = UserDefaults.standard.string(forKey: "vocabularyRoots") ?? "~/work"
        return saved.split(separator: ",").map {
            URL(fileURLWithPath: (String($0).trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath, isDirectory: true)
        }
    }
    static let skipFolders: Set<String> = ["scratch", "node_modules", "build", "dist", "tmp", "temp", "archive", "backup"]

    public static func ensureExists() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("""
            # Words and names Larynx should recognize, one per line. Project names from ~/work and the written side
            # of dictionary.json are added automatically.
            Claude

            """.utf8).write(to: url)
    }

    /// Every term, deduplicated case-insensitively, user entries first.
    public static func terms() -> [String] {
        var seen = Set<String>(), out: [String] = []
        func add(_ t: String) {
            let t = t.trimmingCharacters(in: .whitespaces)
            guard t.count >= 3, !t.hasPrefix("#"), seen.insert(t.lowercased()).inserted else { return }
            out.append(t)
        }
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").forEach { add(String($0)) }
        Dictionary.load().values.forEach(add)
        projectNames().forEach(add)
        if UserDefaults.standard.string(forKey: "devTerms") != "off" { developerTerms.forEach(add) }
        return out
    }

    /// Tools and services developers name all the time. Only distinctive names: short or everyday-sounding ones
    /// ("Rust", "React", "Linear") would risk swapping real words. `defaults write ... devTerms off` removes them.
    static let developerTerms = [
        "Supabase", "MongoDB", "Vercel", "PostgreSQL", "Postgres", "Redis", "Kubernetes", "Docker", "Terraform", "Nginx",
        "GraphQL", "Prisma", "Tailwind", "Svelte", "Webpack", "Django", "FastAPI", "Laravel", "Firebase", "Netlify",
        "Cloudflare", "Heroku", "Twilio", "Datadog", "Grafana", "Kafka", "RabbitMQ", "Elasticsearch", "DynamoDB", "SQLite",
        "MySQL", "Auth0", "Homebrew", "Xcode", "SwiftUI", "Kotlin", "TypeScript", "JavaScript", "PyTorch",
        "TensorFlow", "Ollama", "LangChain", "OpenAI", "Anthropic", "Windsurf", "Copilot", "Codex", "Electron", "Tauri",
        "Vitest", "Playwright", "Cypress", "ESLint", "Prettier", "Figma", "Airtable", "Shopify", "Webflow", "Zapier",
        "FluidAudio", "Parakeet", "CoreML", "Vite", "Nuxt", "Deno", "pnpm", "Sentry", "Drizzle", "Upstash",
    ]

    /// Distinctive names from the folders directly inside each root: a one-word folder ("larynx", "macropad") is kept
    /// as is; from a multi-word one ("govee-lights") only the parts that aren't ordinary English words ("Govee").
    public static func projectNames() -> [String] {
        var names: [String] = []
        for root in roots {
            let folders = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            for folder in folders where !folder.hasPrefix(".") && !skipFolders.contains(folder.lowercased()) {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: root.appendingPathComponent(folder).path, isDirectory: &isDir), isDir.boolValue,
                      !folder.hasSuffix("-wt") else { continue }
                let all = folder.split(whereSeparator: { "-_. ".contains($0) }).map(String.init)
                let parts = all.filter { $0.count >= 4 && $0.allSatisfy(\.isLetter) }
                let keep = all.count == 1 ? parts : parts.filter { !isEnglish($0) }
                names += keep.map { $0.prefix(1).uppercased() + $0.dropFirst() }
            }
        }
        return names
    }

    /// Writes vocabulary names the way they're spelled ("prisma" -> "Prisma", "mongodb" -> "MongoDB"). Only names that
    /// aren't ordinary English, so "roundup" in a sentence stays lowercase.
    public static func fixCase(_ text: String, terms: [String]) -> String {
        var s = text
        for term in terms where !term.contains(" ") {
            s = s.replacingOccurrences(of: "(?i)(?<![\\w.])" + NSRegularExpression.escapedPattern(for: term) + "(?![\\w])",
                                       with: NSRegularExpression.escapedTemplate(for: term), options: .regularExpression)
        }
        return s
    }

    /// The terms `fixCase` should use: everything that isn't an ordinary English word.
    public static func caseTerms(_ terms: [String]) -> [String] { terms.filter { !isEnglish($0) } }

    /// Ordinary English according to macOS's spell checker ("chat", "jobs", "coding"), so they aren't boosted.
    public static func isEnglish(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared
        return checker.checkSpelling(of: word.lowercased(), startingAt: 0, language: "en", wrap: false,
                                     inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }
}
