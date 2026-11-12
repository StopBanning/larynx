import AppKit
import Foundation
import SQLite3
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
    // Kept audio is FLAC: every sample comes back (to 16 bits), in far fewer bytes than the float WAV.
    #expect(kept?.audioPath?.hasSuffix(".flac") == true)
    let restored = try loadAudioFile(URL(fileURLWithPath: kept!.audioPath!))
    #expect(restored.count == tone.count)
    #expect(zip(restored, tone).allSatisfy { abs($0 - $1) < 0.001 })
    let bytes = (try FileManager.default.attributesOfItem(atPath: kept!.audioPath!)[.size] as? Int) ?? .max
    #expect(bytes < tone.count * 4 / 2)
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

@Test func editWatcherKeepsTheLastVersionThatStillHoldsThePaste() {
    let pasted = "Tell Gavy to dim the lights"
    #expect(Learner.stillHolds(pasted, in: "Tell Govee to dim the lights"))
    #expect(Learner.stillHolds(pasted, in: "Hey, Tell Govee to dim the lights please"))
    #expect(!Learner.stillHolds(pasted, in: ""))  // sent
    #expect(!Learner.stillHolds(pasted, in: "Something else entirely"))
    #expect(Learner.fixes(pasted: pasted, now: "Tell Govee to dim the lights").map(\.fixed) == ["Govee"])
    // Capitalisation tidy-ups of ordinary words teach nothing; a name's spelling does.
    #expect(Learner.fixes(pasted: "You know what I mean", now: "you know what I mean").isEmpty)
    #expect(Learner.fixes(pasted: "we moved to prisma today", now: "we moved to Prisma today").map(\.fixed) == ["Prisma"])
}

@Test func builtInTermsNeverReplaceRealEnglishWords() {
    // "next" and the built-in "Nuxt" share every consonant: only a term the user chose may replace a real word.
    #expect(Transcriber.swap("next", for: "Nuxt", in: "What next?") == "What next?")
    #expect(Transcriber.swap("going", for: "Golang", in: "How are things going?") == "How are things going?")
    #expect(Transcriber.swap("next", for: "Nuxt", in: "What next?", personal: ["nuxt"]) == "What Nuxt?")
    // Made-up words the model produced still get fixed by any term.
    #expect(Transcriber.swap("Gavy", for: "Govee", in: "Ask Gavy to dim it") == "Ask Govee to dim it")
    // "macropod" is a real word (a kangaroo's family), so it takes the user's own project name to replace it.
    #expect(Transcriber.swap("macropod", for: "Macropad", in: "my macropod key") == "my macropod key")
    #expect(Transcriber.swap("macropod", for: "Macropad", in: "my macropod key", personal: ["macropad"]) == "my Macropad key")
}

@Test func correctionsAndTheGoldenSetStayPrivateAndFollowTheirDictation() throws {
    let f = try HistoryFixture(#"{"keepAudio": "30"}"#)
    let pending = f.history.begin(samples: tone, app: "com.example.app", mode: .ai, privateField: false)
    let row = try #require(f.history.complete(pending, transcript: f.transcript("Book the Compaq room for Friday."), delivery: "inserted"))
    f.history.recordCorrection(id: row.id, text: "Book the compact room for Friday.", source: "edit")
    f.history.recordCorrection(id: "no-such-dictation", text: "ignored", source: "edit")
    #expect(f.history.corrections().count == 1)
    #expect(f.history.corrections()[row.id]?.text == "Book the compact room for Friday.")

    let clip = try Golden.add(row, text: "Book the compact room for Friday.", source: "edit", root: f.folder)
    #expect(FileManager.default.fileExists(atPath: clip.audio))
    #expect(clip.audio.hasPrefix(Golden.directory(root: f.folder).path))
    let mode = try FileManager.default.attributesOfItem(atPath: clip.audio)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    #expect(Golden.load(root: f.folder).map(\.id) == [row.id])
    #expect(throws: (any Error).self) { try Golden.add(row, text: "  ", source: "user", root: f.folder) }
    #expect(try Golden.remove(id: row.id, root: f.folder))
    #expect(Golden.load(root: f.folder).isEmpty && !FileManager.default.fileExists(atPath: clip.audio))

    // A correction goes when its dictation does.
    f.history.prune(now: Date().addingTimeInterval(40 * 86_400))
    #expect(f.history.corrections().isEmpty)
}

@Test func goldenNamesAndWordFixes() {
    #expect(Golden.names(in: "Ask Priya about Opus. Then I'll ping Claude, okay?") == ["Priya", "Opus", "Claude"])
    #expect(Golden.isWordFix("Can we book the Compaq room before the Robus meeting?", "Can we book the compact room before the Rome bus meeting?"))
    #expect(Golden.isWordFix("Send it to Mike tomorrow morning.", "Send it to Mike tomorrow evening."))
    #expect(!Golden.isWordFix("Send it to Mike tomorrow.", "Send it to Mike tomorrow."))
    #expect(!Golden.isWordFix("Send it to Mike tomorrow.", "Actually, let's wait until next week to decide."))
}

@Test func pastesAreMarkedTransientForClipboardManagers() {
    let board = NSPasteboard(name: NSPasteboard.Name("larynx-test-\(UUID())"))
    defer { board.releaseGlobally() }
    Inserter.writeTransient("Ship it on Friday.", to: board)
    #expect(board.string(forType: .string) == "Ship it on Friday.")
    for type in Inserter.transientTypes { #expect(board.types?.contains(type) == true) }
}

@Test func undoneDictationsAreFlaggedOnce() throws {
    let f = try HistoryFixture()
    let pending = f.history.begin(samples: tone, app: "com.example.app", mode: .ai, privateField: false)
    let row = try #require(f.history.complete(pending, transcript: f.transcript("Send the deck."), delivery: "inserted"))
    f.history.addFlag("undone", to: row.id)
    f.history.addFlag("undone", to: row.id)
    #expect(f.history.recent(limit: 1).first?.flags == ["undone"])
}

@Test func timingIsKeptWithTheDictationAndOldDatabasesGainTheColumn() throws {
    // A database from before the timing column (user_version 1) opens, gains the column and keeps its rows.
    let f = try HistoryFixture()
    var db: OpaquePointer?
    #expect(sqlite3_open(f.history.databaseURL.path, &db) == SQLITE_OK)
    let old = """
        CREATE TABLE dictations (id TEXT PRIMARY KEY, time REAL NOT NULL, app TEXT, mode TEXT, engine TEXT, raw TEXT,
            text TEXT, steps TEXT, audioSeconds REAL, totalMs INTEGER, delivery TEXT, audioPath TEXT, flags TEXT);
        INSERT INTO dictations VALUES ('old-1', \(Date().timeIntervalSince1970 - 10), 'com.example.app', 'ai', 'clean',
            'move the call to noon', 'Move the call to noon.', '[]', 1.2, 60, 'inserted', NULL, '');
        PRAGMA user_version = 1;
        """
    #expect(sqlite3_exec(db, old, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)

    let pending = f.history.begin(samples: tone, app: "com.example.app", mode: .ai, privateField: false)
    let timing = History.Timing(micMs: 0, tailMs: 120, waitMs: 130, asrMs: 80, cleanMs: 9, keyUpToPasteMs: 225,
                                deliverMs: 640, gapSeconds: 31, load: 2.1, accessibilityWasOff: true,
                                reason: "no-focused-element", previewRunning: false)
    f.history.complete(pending, transcript: f.transcript("Book the table for four."), delivery: "pasted+copied", timing: timing)
    let rows = f.history.recent()
    #expect(rows.count == 2)
    #expect(rows.first { $0.id == pending.id }?.timing == timing)
    #expect(rows.first { $0.id == "old-1" }?.timing == nil)
    #expect(timing.summary == "mic 0 tail 120 wait 130 asr 80 clean 9 paste 225 deliver 640 gap 31 s load 2.1 (ax was off) reason no-focused-element")
}
