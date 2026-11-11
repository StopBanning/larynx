import AppKit
import AVFoundation
import Foundation
import LarynxCore

// MARK: - Engine

let transcriber = Transcriber()
let recorder = Recorder()
nonisolated(unsafe) var activeHotkey: Hotkey?
let engine: Engine = option("--engine").flatMap(Engine.init(rawValue:))
    ?? Engine(rawValue: Settings.shared.string(.engine)) ?? .clean
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
        try await transcriber.loadVocabulary(terms, modelsDir: modelsDir)
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
func transcribeWithFallback(_ samples: [Float]) async throws -> (text: String, engine: String) {
    let forced = ProcessInfo.processInfo.environment["LARYNX_FORCE_FALLBACK"] == "1"
    let first = forced ? "" : try await transcriber.transcribe(samples)
    guard first.isEmpty else { return (first, engine.rawValue) }
    let seconds = Double(samples.count) / Recorder.sampleRate, level = Recorder.rms(samples)
    guard seconds >= 0.5, level >= 0.01 || forced, engine.other.isDownloaded(in: modelsDir) else { return (first, engine.rawValue) }
    try await FallbackLoader.shared.task.value
    let second = try await fallbackTranscriber.transcribe(samples)
    logTranscript("fallback engine: \(engine.other.rawValue) (\(String(format: "%.1f", seconds)) s, rms \(String(format: "%.3f", level))): \(second.isEmpty ? "also empty" : "heard \(second.split(separator: " ").count) words")", text: second)
    return (second, engine.other.rawValue)
}

func requestMicrophone() async -> Bool {
    if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return true }
    return await AVCaptureDevice.requestAccess(for: .audio)
}

/// Transcribes, optionally cleans, and reports timing for one utterance.
func finish(_ samples: [Float], clean: Bool, mode: CleanupMode = .standard, tidy: Bool = !verbatim) async throws -> Transcript {
    let started = Date()
    try await Loader.shared.task.value
    if !inApp { await Loader.shared.vocabulary.value }  // command line: results should be repeatable
    let (raw, usedEngine) = try await transcribeWithFallback(samples)
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
    result.totalMs = ms(since: started)
    return result
}

