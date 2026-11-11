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

/// Which speech model to run. All are Parakeet 0.6B family models on the Neural Engine.
public enum Engine: String, CaseIterable, Sendable {
    /// Parakeet TDT v3: verbatim, 25 European languages.
    case parakeet
    /// Underdog Bark 3.0 Clean: English only; drops fillers, false starts and repeated words as it transcribes.
    case clean
    /// Underdog Bark 3.0: English, verbatim (keeps "um", repeats).
    case bark3
    /// Parakeet Ultra: moondream's post-training of v3, same 25 languages, more accurate on FluidAudio's benchmarks.
    case ultra
    /// Parakeet Unified 0.6B: English with punctuation and capitals from the model itself.
    case unified

    var version: AsrModelVersion {
        switch self {
        case .clean: return .bark3Clean
        case .bark3: return .bark3
        case .ultra: return .ultra
        case .parakeet, .unified: return .v3
        }
    }
    public var folder: String {
        switch self {
        case .clean: return "bark-3.0-clean"
        case .bark3: return "bark-3.0"
        case .ultra: return "parakeet-ultra"
        case .parakeet: return "parakeet-tdt-0.6b-v3"
        case .unified: return "parakeet-unified-en-0.6b"  // the folder FluidAudio downloads it into
        }
    }
    /// The second-chance model when this one hears nothing.
    public var other: Engine { self == .parakeet || self == .ultra ? .clean : .parakeet }

    /// True when this model is already on disk, so using it never triggers a download.
    public func isDownloaded(in modelsDir: URL?) -> Bool {
        guard let modelsDir else { return false }
        let dir = modelsDir.appendingPathComponent(folder, isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.hasSuffix(".mlmodelc") }
    }

    public var modelName: String { folder }
}

/// What the speech model heard, with how sure it was.
public struct Heard: Sendable {
    public var text: String
    public var confidence: Float
    public var words: [WordConfidence]
    public init(text: String, confidence: Float, words: [WordConfidence]) { self.text = text; self.confidence = confidence; self.words = words }
}

public struct WordConfidence: Sendable, Codable, Equatable {
    public var word: String
    public var confidence: Float
    public init(word: String, confidence: Float) { self.word = word; self.confidence = confidence }
}

/// Runs NVIDIA Parakeet TDT v3 (25 European languages) on the Neural Engine through FluidAudio. Fully offline after the first model download.
public actor Transcriber {
    private var manager: AsrManager?
    private var unified: UnifiedAsrManager?
    private var boosting: VocabularyBoostingSession?
    public private(set) var vocabularySize = 0
    /// Terms the user chose (vocabulary.txt, the dictionary, things learned, their project folders). Only these may
    /// replace a real English word; built-in developer names may only replace words the model made up.
    private var personal: Set<String> = []

    public init() {}

    public var isLoaded: Bool { manager != nil || unified != nil }

    /// Downloads the model on first run (about 500 MB), then loads it from `modelsDir` or FluidAudio's default folder.
    public func load(modelsDir: URL? = nil, engine: Engine = .parakeet) async throws {
        guard manager == nil, unified == nil else { return }
        if engine == .unified {
            let u = UnifiedAsrManager()
            try await u.loadModels(to: modelsDir)
            unified = u
            return
        }
        // FluidAudio treats the path as the model's own folder, so give it a subfolder of modelsDir.
        let target = modelsDir?.appendingPathComponent(engine.folder, isDirectory: true)
        let models = try await AsrModels.downloadAndLoad(to: target, version: engine.version)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        manager = asr
    }

    /// Loads the small keyword model (Parakeet CTC 110M, downloaded once into `modelsDir`) and the terms to listen for.
    /// Afterwards each transcript is rescored against the audio, and close-sounding words are swapped for your terms.
    public func loadVocabulary(_ terms: [String], personal: Set<String> = [], modelsDir: URL?) async throws {
        self.personal = Set(personal.map { $0.lowercased() })
        guard !terms.isEmpty else { boosting = nil; vocabularySize = 0; return }
        let ctc = try await CtcModels.downloadAndLoad(to: modelsDir?.appendingPathComponent("parakeet-ctc-110m-coreml", isDirectory: true))
        let context = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) })
        boosting = try await VocabularyBoostingSession(vocabulary: context, ctcModels: ctc)
        vocabularySize = boosting?.vocabulary.terms.count ?? 0
    }

    /// Returns the transcript for 16 kHz mono samples. Clips shorter than a quarter second come back empty.
    public func transcribe(_ samples: [Float]) async throws -> String { try await transcribeDetailed(samples).text }

    /// The transcript with the model's confidence: overall, and per word (the lowest token confidence in the word),
    /// taken before vocabulary swaps.
    public func transcribeDetailed(_ samples: [Float]) async throws -> Heard {
        guard manager != nil || unified != nil else { throw LarynxError.notLoaded }
        guard samples.count >= Int(Recorder.sampleRate / 4) else { return Heard(text: "", confidence: 1, words: []) }
        let result: ASRResult
        if let unified {
            result = try await unified.transcribeDetailed(samples)
        } else {
            var state = try TdtDecoderState()
            result = try await manager!.transcribe(samples, decoderState: &state)
        }
        var text = result.text
        if let boosting, let timings = result.tokenTimings, !timings.isEmpty,
           let out = await boosting.rescore(text: text, tokenTimings: timings, audioSamples: samples), out.wasModified {
            // FluidAudio's own rewritten text is far too eager with a short word list ("update to GitHub" -> "update to Govee"),
            // so take only its one-word swaps where the heard word looks like the term ("Gavy" -> "Govee").
            for r in out.replacements where r.shouldReplace {
                guard let term = r.replacementWord else { continue }
                text = Transcriber.swap(r.originalWord, for: term, in: text, personal: personal)
            }
        }
        return Heard(text: text.trimmingCharacters(in: .whitespacesAndNewlines), confidence: result.confidence,
                     words: Transcriber.words(from: result.tokenTimings ?? []))
    }

    /// Joins sentencepiece tokens into words ("▁Com" "paq" -> "Compaq"), keeping each word's lowest confidence.
    static func words(from timings: [TokenTiming]) -> [WordConfidence] {
        var out: [WordConfidence] = []
        for t in timings {
            let starts = t.token.hasPrefix("▁") || t.token.hasPrefix(" ")
            let piece = t.token.replacingOccurrences(of: "▁", with: "").trimmingCharacters(in: .whitespaces)
            if starts || out.isEmpty {
                if !piece.isEmpty { out.append(WordConfidence(word: piece, confidence: t.confidence)) }
            } else if !piece.isEmpty {
                out[out.count - 1].word += piece
                out[out.count - 1].confidence = min(out[out.count - 1].confidence, t.confidence)
            }
        }
        return out
    }

    /// Replaces one word with a vocabulary term when they sound alike: same first letter and nearly the same consonants
    /// ("macropod"/"Macropad", "Gavie"/"Govee"). A real English word the model heard ("next", "going") is only replaced
    /// by a term the user chose, and only when the consonants match exactly: "next" never becomes the built-in "Nuxt".
    static func swap(_ heard: String, for term: String, in text: String, personal: Set<String> = []) -> String {
        // A suggestion can cover a few words ("Gavy app"); swap only the one that sounds like the term.
        let words = heard.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }
        let chosen = personal.contains(term.lowercased())
        guard !term.contains(" "), let h = words.first(where: { word in
            guard word.lowercased() != term.lowercased() else { return false }
            if Vocabulary.isEnglish(word) { return chosen && soundsAlike(word, term, strict: true) }
            return soundsAlike(word, term)
        }) else { return text }
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
