import AppKit
import AVFoundation
import Foundation
import LarynxCore
import LarynxText

// MARK: - Engine

let transcriber = Transcriber()
let recorder = Recorder()
nonisolated(unsafe) var activeHotkey: Hotkey?
let engine: Engine = option("--engine").flatMap(Engine.init(rawValue:))
    ?? Engine(rawValue: Settings.shared.string(.engine)) ?? .ultra
/// Loads the speech model on first use only, so text-only commands never touch it.
final class Loader: @unchecked Sendable {
    static let shared = Loader()
    lazy var task: Task<Void, Error> = Task { try await transcriber.load(modelsDir: modelsDir, engine: engine) }
    /// Your vocabulary (project names, dictionary, vocabulary.txt). Loads after the speech model; the app doesn't wait for it.
    lazy var vocabulary: Task<Void, Never> = Task { await reloadVocabulary() }
}

/// `--vocab off` or `defaults write com.automatedworkflow.larynx vocabulary off` turns vocabulary boosting off.
var vocabularyEnabled: Bool { (option("--vocab") ?? Settings.shared.string(.vocabulary)) != "off" }

/// Vocabulary names to write with their own spelling ("prisma" -> "Prisma"); filled when the vocabulary loads.
final class VocabularyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var terms: [String] {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
let vocabularyCache = VocabularyCache()

func reloadVocabulary() async {
    do {
        try await Loader.shared.task.value
        let started = Date()
        let terms = vocabularyEnabled ? Vocabulary.terms() : []
        vocabularyCache.terms = Vocabulary.caseTerms(terms)
        try await transcriber.loadVocabulary(terms, personal: vocabularyEnabled ? Vocabulary.personalTerms() : [], modelsDir: modelsDir)
        if !terms.isEmpty { log("vocabulary: \(await transcriber.vocabularySize) words in \(ms(since: started)) ms") }
    } catch {
        log("vocabulary failed to load: \(error)")
    }
}

/// The other speech model, used only when the main one hears nothing in a clip that clearly has speech in it.
let fallbackTranscriber = Transcriber()
final class FallbackLoader: @unchecked Sendable {
    static let shared = FallbackLoader()
    lazy var task: Task<Void, Error> = Task { try await fallbackTranscriber.load(modelsDir: modelsDir, engine: engine.other) }
}

/// Retries an empty transcript with the other model when the clip is long and loud enough to be speech
/// and that model is already downloaded. `LARYNX_FORCE_FALLBACK=1` treats every first pass as empty, for testing.
func transcribeWithFallback(_ samples: [Float]) async throws -> (heard: Heard, engine: String) {
    let forced = ProcessInfo.processInfo.environment["LARYNX_FORCE_FALLBACK"] == "1"
    let first = forced ? Heard(text: "", confidence: 1, words: []) : try await transcriber.transcribeDetailed(samples)
    guard first.text.isEmpty else { return (first, engine.rawValue) }
    let seconds = Double(samples.count) / Recorder.sampleRate, level = Recorder.rms(samples)
    guard seconds >= 0.5, level >= 0.01 || forced, engine.other.isDownloaded(in: modelsDir) else { return (first, engine.rawValue) }
    try await FallbackLoader.shared.task.value
    let second = try await fallbackTranscriber.transcribeDetailed(samples)
    logTranscript("fallback engine: \(engine.other.rawValue) (\(String(format: "%.1f", seconds)) s, rms \(String(format: "%.3f", level))): \(second.text.isEmpty ? "also empty" : "heard \(second.text.split(separator: " ").count) words")", text: second.text)
    return (second, engine.other.rawValue)
}

func requestMicrophone() async -> Bool {
    if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return true }
    return await AVCaptureDevice.requestAccess(for: .audio)
}

/// Transcribes, optionally cleans, and reports timing for one utterance.
func finish(_ samples: [Float], clean: Bool, mode: CleanupMode = .standard, tidy: Bool = !verbatim,
            screen: [String]? = nil) async throws -> Transcript {
    let started = Date()
    try await Loader.shared.task.value
    if !inApp { await Loader.shared.vocabulary.value }  // command line: results should be repeatable
    let (heard, usedEngine) = try await transcribeWithFallback(samples)
    let raw = heard.text
    let asrMs = ms(since: started)
    let input = Transcript(text: raw, raw: raw, engine: usedEngine, mode: mode,
                           audioSeconds: (Double(samples.count) / Recorder.sampleRate * 100).rounded() / 100,
                           asrMs: asrMs, rewriteMs: 0, totalMs: 0, rewrite: "off", rewritten: false)
    let settings = Settings.shared.snapshot()
    let rewrite = (option("--rewrite") ?? settings.string(.rewrite)) == "auto"
    let context = Pipeline.Context(tidy: tidy, rewrite: rewrite, forceRewrite: clean,
                                   snippets: tidy ? Snippets.load() : [:], dictionary: tidy ? Dictionary.load() : [:],
                                   caseTerms: vocabularyCache.terms, settings: settings)
    var result = await Pipeline().run(input, context: context)
    // Homophones settled by the names on screen ("doc" -> "Dock"), in shadow: recorded, not applied yet.
    if let terms = screen, let proposal = ContextWords.proposal(result.text, screenTerms: terms) {
        result.steps.append(Step(stage: "shadow:context", before: result.text, after: proposal, applied: false))
    }
    result.confidence = (Double(heard.confidence) * 1000).rounded() / 1000
    let doubtful = Doubt.words(heard.words.map { ($0.word, $0.confidence) }, finalText: result.text,
                               isKnown: { word in Vocabulary.isEnglish(word) || vocabularyCache.terms.contains { $0.lowercased() == word } })
    result.doubtful = doubtful.isEmpty ? nil : doubtful
    result.totalMs = ms(since: started)
    return result
}

