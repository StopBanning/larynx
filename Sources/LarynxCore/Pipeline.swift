import Foundation
import LarynxText

/// Ordered cleanup decisions. All text changes (including shadow proposals) are recorded as Steps.
public struct Pipeline {
    public struct Context {
        public var tidy: Bool
        public var rewrite: Bool
        public var forceRewrite: Bool
        public var snippets: [String: String]
        public var dictionary: [String: String]
        public var caseTerms: [String]
        public var settings: Settings.Snapshot

        public init(tidy: Bool = true, rewrite: Bool = true, forceRewrite: Bool = false,
                    snippets: [String: String] = [:], dictionary: [String: String] = [:],
                    caseTerms: [String] = [], settings: Settings.Snapshot = .init()) {
            self.tidy = tidy
            self.rewrite = rewrite
            self.forceRewrite = forceRewrite
            self.snippets = snippets
            self.dictionary = dictionary
            self.caseTerms = caseTerms
            self.settings = settings
        }
    }

    public struct Stage {
        public let name: String
        public let setting: Settings.Key
        public let enabled: (Context) -> Bool
        public let run: (Transcript, Context) async -> Transcript

        public init(name: String, setting: Settings.Key, enabled: @escaping (Context) -> Bool = { _ in true }, run: @escaping (Transcript, Context) async -> Transcript) {
            self.name = name
            self.setting = setting
            self.enabled = enabled
            self.run = run
        }
    }

    public let stages: [Stage]
    public init(stages: [Stage] = Pipeline.standardStages) { self.stages = stages }

    public func run(_ input: Transcript, context: Context) async -> Transcript {
        var result = input
        for stage in stages {
            let mode = stage.enabled(context) ? context.settings.stageMode(stage.setting) : .off
            let before = result.text
            let proposed = mode == .off ? result : await stage.run(result, context)
            if mode == .on { result = proposed }
            if mode == .shadow, stage.setting == .rewriteStage {
                result.rewrite = "shadow: " + proposed.rewrite
                result.rewriteMs = proposed.rewriteMs
            }
            result.steps.append(Step(stage: stage.name, before: before, after: proposed.text, applied: mode == .on))
            // Matched snippets are literal saved text: no later stage, including rewrite, may touch them.
            if result.snippet != nil { break }
        }
        return result
    }

    public static let standardStages: [Stage] = [
        Stage(name: "snippet", setting: .snippetStage, enabled: { $0.tidy }) { input, context in
            var result = input
            if context.tidy, let match = Snippets.match(input.text, in: context.snippets) {
                result.text = match.text
                result.snippet = match.cue
                result.rewrite = "snippet"
                result.rewritten = false
                result.rewriteMs = 0
            }
            return result
        },
        Stage(name: "dictionary", setting: .dictionaryStage, enabled: { $0.tidy }) { input, context in
            var result = input
            if context.tidy { result.text = Dictionary.apply(input.text, map: context.dictionary) }
            return result
        },
        Stage(name: "vocabularyCase", setting: .vocabularyCaseStage, enabled: { $0.tidy }) { input, context in
            var result = input
            if context.tidy { result.text = Vocabulary.fixCase(input.text, terms: context.caseTerms) }
            return result
        },
        Stage(name: "tidy", setting: .tidyStage, enabled: { $0.tidy }) { input, context in
            var result = input
            if context.tidy { result.text = Tidy.apply(input.text, mode: input.mode) }
            return result
        },
        // Spoken numbers to digits in every mode, AI apps included ("Opus five point five" -> "Opus 5.5").
        Stage(name: "numbers", setting: .numbersStage, enabled: { $0.tidy }) { input, context in
            var result = input
            if context.tidy { result.text = Numbers.apply(input.text) }
            return result
        },
        Stage(name: "rewrite", setting: .rewriteStage, enabled: { $0.rewrite || $0.forceRewrite }) { input, context in
            var result = input
            let started = Date()
            let outcome = context.rewrite || context.forceRewrite
                ? await Cleaner.rewrite(input.text, mode: input.mode, force: context.forceRewrite)
                : Cleaner.Outcome(text: input.text, used: false, note: "off")
            result.text = outcome.text
            result.rewrite = outcome.note
            result.rewritten = outcome.used
            result.rewriteMs = outcome.note == "off" ? 0 : Int(Date().timeIntervalSince(started) * 1000)
            return result
        },
    ]
}
