import FluidAudio
import Foundation

/// Speaker separation for the call side of a meeting (docs/MEETINGS.md), with FluidAudio's on-device diarizer
/// (pyannote community-1, WeSpeaker and BUT Speech@FIT models, CC BY 4.0, converted to Core ML by FluidInference).
/// The models (about 129 MB) download once into Larynx's models folder.
public actor MeetingDiarizer {
    private var manager: DiarizerManager?

    public init() {}

    public static func folder(_ modelsDir: URL?) -> URL? {
        modelsDir?.appendingPathComponent("speaker-diarization-coreml", isDirectory: true)
    }

    public func load(modelsDir: URL?) async throws {
        guard manager == nil else { return }
        let models = try await DiarizerModels.downloadIfNeeded(to: Self.folder(modelsDir))
        let m = DiarizerManager()
        m.initialize(models: models)
        manager = m
    }

    /// Who spoke when, in seconds, over the whole call track.
    public func turns(_ samples: [Float], rate: Int = 16_000) throws -> [MeetingSpeakers.Turn] {
        guard let manager, samples.count > rate else { return [] }
        let result = try manager.performCompleteDiarization(samples, sampleRate: rate)
        return result.segments.map { MeetingSpeakers.Turn(start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds), speaker: $0.speakerId) }
    }
}
