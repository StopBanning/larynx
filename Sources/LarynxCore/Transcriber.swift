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
    var folder: String { self == .clean ? "bark-3.0-clean" : "parakeet-tdt-0.6b-v3" }
    public var modelName: String { self == .clean ? "bark-3.0-clean" : "parakeet-tdt-0.6b-v3" }
}

/// Runs NVIDIA Parakeet TDT v3 (25 European languages) on the Neural Engine through FluidAudio. Fully offline after the first model download.
public actor Transcriber {
    private var manager: AsrManager?

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

    /// Returns the transcript for 16 kHz mono samples. Clips shorter than a quarter second come back empty.
    public func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { throw LarynxError.notLoaded }
        guard samples.count >= Int(Recorder.sampleRate / 4) else { return "" }
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
