import Foundation
import Testing
@testable import LarynxCore

private final class HistoryFixture {
    let folder: URL
    let suite: String
    let defaults: UserDefaults
    let settings: Settings
    let history: History
    init(_ json: String = "{}") throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("larynx-history-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suite = "larynx-history-tests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        settings = Settings(url: folder.appendingPathComponent("settings.json"), defaults: defaults)
        try Data(json.utf8).write(to: settings.url)
        history = History(root: folder, settings: settings)
    }
    deinit {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }
    func transcript(_ text: String) -> Transcript {
        Transcript(text: text, raw: text.lowercased(), engine: "clean", mode: .ai, audioSeconds: 1.5, asrMs: 40,
                   rewriteMs: 0, totalMs: 55, rewrite: "not needed", rewritten: false,
                   steps: [Step(stage: "tidy", before: text.lowercased(), after: text, applied: true)])
    }
    var spoolFiles: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: history.spoolDir.path)) ?? []).sorted() }
}

private let tone: [Float] = (0..<16_000).map { sinf(Float($0) * 0.05) * 0.2 }

@Test func spoolExistsBeforeTranscriptionAndClearsAfterSaving() throws {
    let f = try HistoryFixture()
    let pending = f.history.begin(samples: tone, app: "com.example.app", mode: .ai, privateField: false)
    #expect(pending.persists)
    #expect(f.spoolFiles == ["\(pending.id).json", "\(pending.id).wav"])
    let row = f.history.complete(pending, transcript: f.transcript("Ship the deploy on Friday."), delivery: "inserted")
    #expect(row?.text == "Ship the deploy on Friday.")
    #expect(f.spoolFiles.isEmpty)
    let saved = f.history.recent()
    #expect(saved.count == 1)
    #expect(saved.first?.steps.first?.stage == "tidy")
    #expect(saved.first?.app == "com.example.app")
    #expect(saved.first?.audioPath == nil)  // keepAudio defaults to off
}

@Test func spooledAudioRoundTripsThroughTheWAVFile() throws {
    let f = try HistoryFixture()
    let pending = f.history.begin(samples: tone, app: nil, mode: .standard, privateField: false)
    // A single AVAudioFile read returns only part of a float WAV; every sample must come back.
    #expect((try? loadAudioFile(pending.spool!).count) == tone.count)
    let left = f.history.abandoned(olderThan: Date().addingTimeInterval(60))
    #expect(left.count == 1)
    #expect(left.first?.pending.id == pending.id)
    #expect(left.first?.samples.count == tone.count)
    #expect(abs((left.first?.samples[100] ?? 0) - tone[100]) < 1e-6)
    // A recording still in progress (newer than the cutoff) is not touched.
    #expect(f.history.abandoned(olderThan: Date().addingTimeInterval(-60)).isEmpty)
}

@Test func privateFieldsAndHistoryOffNeverTouchTheDisk() throws {
    let f = try HistoryFixture()
    let secret = f.history.begin(samples: tone, app: "com.apple.Passwords", mode: .standard, privateField: true)
    #expect(!secret.persists)
    #expect(f.history.complete(secret, transcript: f.transcript("hunter two"), delivery: "inserted") == nil)
    #expect(f.spoolFiles.isEmpty)
    let off = try HistoryFixture(#"{"history":"off"}"#)
    let pending = off.history.begin(samples: tone, app: nil, mode: .standard, privateField: false)
    #expect(!pending.persists)
    #expect(off.history.complete(pending, transcript: off.transcript("Nothing saved."), delivery: "inserted") == nil)
    #expect(!FileManager.default.fileExists(atPath: off.history.databaseURL.path))
    #expect(Privacy.builtInApps.contains("com.apple.Passwords"))
}

@Test func searchMatchesWordsAndPrefixesAndSurvivesPunctuation() throws {
    let f = try HistoryFixture()
    for text in ["Ship the deploy on Friday.", "Lunch with Priya tomorrow?", "Deploying the hotfix now."] {
        let p = f.history.begin(samples: tone, app: nil, mode: .ai, privateField: false)
        f.history.complete(p, transcript: f.transcript(text), delivery: "inserted")
    }
    #expect(Set(f.history.search("deplo").map(\.text)) == ["Ship the deploy on Friday.", "Deploying the hotfix now."])
    #expect(f.history.search("priya lunch").map(\.text) == ["Lunch with Priya tomorrow?"])
    #expect(f.history.search("\"); DROP TABLE dictations; --").isEmpty)
    #expect(f.history.recent().count == 3)
}

@Test func retentionPrunesOldTextAndKeepAudioMovesTheRecording() throws {
    let f = try HistoryFixture(#"{"historyDays":7,"keepAudio":"3"}"#)
    let old = f.history.begin(samples: tone, app: nil, mode: .ai, privateField: false, now: Date().addingTimeInterval(-10 * 86_400))
    let kept = f.history.complete(old, transcript: f.transcript("Old words."), delivery: "inserted")
    #expect(kept?.audioPath != nil)
    #expect(FileManager.default.fileExists(atPath: kept?.audioPath ?? ""))
    let fresh = f.history.begin(samples: tone, app: nil, mode: .ai, privateField: false)
    f.history.complete(fresh, transcript: f.transcript("New words."), delivery: "inserted")
    #expect(f.history.recent().map(\.text) == ["New words."])  // complete() prunes the 10-day-old row
    #expect(f.history.search("old").isEmpty)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-5 * 86_400)], ofItemAtPath: kept!.audioPath!)
    f.history.prune()
    #expect(!FileManager.default.fileExists(atPath: kept!.audioPath!))
}

@Test func emptyTranscriptsAreNotSaved() throws {
    let f = try HistoryFixture()
    let p = f.history.begin(samples: tone, app: nil, mode: .ai, privateField: false)
    #expect(f.history.complete(p, transcript: f.transcript(""), delivery: "inserted") == nil)
    #expect(f.spoolFiles.isEmpty)
    #expect(f.history.recent().isEmpty)
}
