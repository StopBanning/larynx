import FluidAudio
import Foundation

public enum LarynxError: Error, CustomStringConvertible {
    case noMicrophone, unreadableAudio, notLoaded, notTrusted, secureInput

    public var description: String {
        switch self {
        case .noMicrophone: return "no microphone input available"
        case .unreadableAudio: return "could not read that audio"
        case .notLoaded: return "speech model is not loaded yet"
        case .notTrusted: return "Accessibility permission is needed to paste into other apps"
        case .secureInput: return "a password field has Secure Input on, so pasting is blocked"
        }
    }
}

/// Which speech model to run. All are Parakeet TDT 0.6B variants on the Neural Engine.
public enum Engine: String, CaseIterable, Sendable {
    /// Parakeet TDT v3: verbatim, 25 European languages.
    case parakeet
    /// Underdog Bark 3.0 Clean: English only; drops fillers, false starts and repeated words as it transcribes.
    case clean

    var version: AsrModelVersion { self == .clean ? .bark3Clean : .v3 }
    public var folder: String { self == .clean ? "bark-3.0-clean" : "parakeet-tdt-0.6b-v3" }
    public var other: Engine { self == .clean ? .parakeet : .clean }

    /// True when this model is already on disk, so using it never triggers a download.
    public func isDownloaded(in modelsDir: URL?) -> Bool {
        guard let modelsDir else { return false }
        let dir = modelsDir.appendingPathComponent(folder, isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.hasSuffix(".mlmodelc") }
    }

    public var modelName: String { self == .clean ? "bark-3.0-clean" : "parakeet-tdt-0.6b-v3" }
}

/// Runs NVIDIA Parakeet TDT v3 (25 European languages) on the Neural Engine through FluidAudio. Fully offline after the first model download.
public actor Transcriber {
    private var manager: AsrManager?
    private var boosting: VocabularyBoostingSession?
    public private(set) var vocabularySize = 0

    public init() {}

    public var isLoaded: Bool { manager != nil }

    /// Downloads the model on first run (about 500 MB), then loads it from `modelsDir` or FluidAudio's default folder.
    public func load(modelsDir: URL? = nil, engine: Engine = .parakeet) async throws {
        guard manager == nil else { return }
        // FluidAudio treats the path as the model's own folder, so give it a subfolder of modelsDir.
        let target = modelsDir?.appendingPathComponent(engine.folder, isDirectory: true)
        let models = try await AsrModels.downloadAndLoad(to: target, version: engine.version)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        manager = asr
    }

    /// Loads the small keyword model (Parakeet CTC 110M, downloaded once into `modelsDir`) and the terms to listen for.
    /// Afterwards each transcript is rescored against the audio, and close-sounding words are swapped for your terms.
    public func loadVocabulary(_ terms: [String], modelsDir: URL?) async throws {
        guard !terms.isEmpty else { boosting = nil; vocabularySize = 0; return }
        let ctc = try await CtcModels.downloadAndLoad(to: modelsDir?.appendingPathComponent("parakeet-ctc-110m-coreml", isDirectory: true))
        let context = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) })
        boosting = try await VocabularyBoostingSession(vocabulary: context, ctcModels: ctc)
        vocabularySize = boosting?.vocabulary.terms.count ?? 0
    }

    /// Returns the transcript for 16 kHz mono samples. Clips shorter than a quarter second come back empty.
    public func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { throw LarynxError.notLoaded }
        guard samples.count >= Int(Recorder.sampleRate / 4) else { return "" }
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &state)
        var text = result.text
        if let boosting, let timings = result.tokenTimings, !timings.isEmpty,
           let out = await boosting.rescore(text: text, tokenTimings: timings, audioSamples: samples), out.wasModified {
            // FluidAudio's own rewritten text is far too eager with a short word list ("update to GitHub" -> "update to Govee"),
            // so take only its one-word swaps where the heard word looks like the term ("Gavy" -> "Govee").
            for r in out.replacements where r.shouldReplace {
                guard let term = r.replacementWord else { continue }
                text = Transcriber.swap(r.originalWord, for: term, in: text)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replaces one word with a vocabulary term when they sound alike: same first letter and nearly the same consonants
    /// ("macropod"/"Macropad", "Gavie"/"Govee", "locus"/"Locust"). Anything else is left as heard.
    static func swap(_ heard: String, for term: String, in text: String) -> String {
        // A suggestion can cover a few words ("Gavy app"); swap only the one that sounds like the term.
        let words = heard.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }
        guard !term.contains(" "), let h = words.first(where: { $0.lowercased() != term.lowercased() && soundsAlike($0, term, strict: Vocabulary.isEnglish($0)) })
        else { return text }
        let pattern = "(?i)\\b" + NSRegularExpression.escapedPattern(for: h) + "\\b"
        guard let range = text.range(of: pattern, options: .regularExpression) else { return text }
        return text.replacingCharacters(in: range, with: term)
    }

    /// `strict` (for a real English word the model heard, like "going") demands identical consonants, so only near
    /// misspellings ("macropod" -> "Macropad") change; "going" never becomes "Golang".
    public static func soundsAlike(_ a: String, _ b: String, strict: Bool = false) -> Bool {
        func skeleton(_ s: String) -> [Character] {
            Array(s.lowercased().filter { $0.isLetter && !"aeiouy".contains($0) })
        }
        let x = skeleton(a), y = skeleton(b)
        guard x.count >= 2, y.count >= 2, a.lowercased().first == b.lowercased().first else { return false }
        var d = Array(0...y.count)  // edit distance between the consonant skeletons
        for i in 1...x.count {
            var prev = d[0]; d[0] = i
            for j in 1...y.count {
                let cur = min(d[j] + 1, d[j - 1] + 1, prev + (x[i - 1] == y[j - 1] ? 0 : 1))
                prev = d[j]; d[j] = cur
            }
        }
        return d[y.count] <= (strict ? 0 : max(x.count, y.count) / 4)
    }
}
