import AVFoundation
import Foundation
import SQLite3

/// Dictation history on this Mac: SQLite with a full-text index, plus a crash spool for audio.
///
/// The spool is how a crash can't lose words: a finished recording is written to `history/spool/<id>.wav` before
/// transcription starts and removed once the transcript is saved. Anything left in the spool at launch is
/// transcribed again and saved as a recovered dictation.
public final class History: @unchecked Sendable {
    public struct Row: Codable, Equatable, Sendable {
        public var id: String
        public var time: Date
        public var app: String?
        public var mode: String
        public var engine: String
        public var raw: String
        public var text: String
        public var steps: [Step]
        public var audioSeconds: Double
        public var totalMs: Int
        public var delivery: String
        public var audioPath: String?
        public var flags: [String]
        /// Where the time went and why a paste wasn't confirmed (numbers and codes, never text). Nil on old rows.
        public var timing: Timing? = nil
    }

    /// One dictation's time split, from key-down to delivered, and the delivery's reason code. Recorded so a slow or
    /// unconfirmed dictation can be explained afterwards (`larynx review`); holds no text.
    public struct Timing: Codable, Equatable, Sendable {
        /// Microphone start at key-down (0 when it was already warm).
        public var micMs: Int?
        /// Listening kept on after key-up because a word was still being said.
        public var tailMs: Int?
        /// Key-up to the start of transcription (the tail, plus writing the spool).
        public var waitMs: Int?
        public var asrMs: Int?
        /// Cleanup after the speech model (dictionary, tidy, numbers, rewrite, doubt).
        public var cleanMs: Int?
        /// Key-up until ⌘V was sent (or the words were inserted another way): what you wait for.
        public var keyUpToPasteMs: Int?
        /// Inside delivery: bringing the app back, reading the field, pasting, checking.
        public var deliverMs: Int?
        /// Seconds since the previous dictation ended (nil for the first one after launch).
        public var gapSeconds: Int?
        /// The machine's 1-minute load average at key-up.
        public var load: Double?
        /// The app's accessibility tree was off at key-down (Larynx had switched it off, or never on).
        public var accessibilityWasOff: Bool?
        /// Why the paste wasn't confirmed, as a short code (nil when it was).
        public var reason: String?
        /// A live-preview transcription was still running at key-up (the final one waits for it).
        public var previewRunning: Bool?

        public init(micMs: Int? = nil, tailMs: Int? = nil, waitMs: Int? = nil, asrMs: Int? = nil, cleanMs: Int? = nil,
                    keyUpToPasteMs: Int? = nil, deliverMs: Int? = nil, gapSeconds: Int? = nil, load: Double? = nil,
                    accessibilityWasOff: Bool? = nil, reason: String? = nil, previewRunning: Bool? = nil) {
            self.micMs = micMs; self.tailMs = tailMs; self.waitMs = waitMs; self.asrMs = asrMs; self.cleanMs = cleanMs
            self.keyUpToPasteMs = keyUpToPasteMs; self.deliverMs = deliverMs; self.gapSeconds = gapSeconds
            self.load = load; self.accessibilityWasOff = accessibilityWasOff; self.reason = reason
            self.previewRunning = previewRunning
        }

        /// One line for the log: "wait 12 asr 80 clean 9 paste 104 deliver 640 gap 31 s load 2.1 (ax was off) reason x".
        public var summary: String {
            var parts: [String] = []
            func add(_ name: String, _ v: Int?) { if let v { parts.append("\(name) \(v)") } }
            add("mic", micMs); add("tail", tailMs); add("wait", waitMs); add("asr", asrMs); add("clean", cleanMs)
            add("paste", keyUpToPasteMs); add("deliver", deliverMs)
            if let gapSeconds { parts.append("gap \(gapSeconds) s") }
            if let load { parts.append(String(format: "load %.1f", load)) }
            if accessibilityWasOff == true { parts.append("(ax was off)") }
            if previewRunning == true { parts.append("(preview running)") }
            if let reason { parts.append("reason " + reason) }
            return parts.joined(separator: " ")
        }
    }

    /// A recording that has been spooled (or deliberately not) and is waiting for its transcript.
    public struct Pending: Sendable {
        public let id: String
        public let time: Date
        public let app: String?
        public let mode: CleanupMode
        /// Nil when nothing may touch the disk: history off, a password field or an app on the privacy list.
        public let spool: URL?
        public var persists: Bool { spool != nil }
    }

    /// What the spool keeps next to the audio, so a recovery knows where the words were going.
    struct SpoolMeta: Codable { var id: String; var time: Date; var app: String?; var mode: CleanupMode }

    public static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Larynx", isDirectory: true)
    /// `LARYNX_DATA_DIR` moves history and the spool somewhere else (tests never touch the real history).
    public static let shared = History(root: ProcessInfo.processInfo.environment["LARYNX_DATA_DIR"]
        .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) } ?? defaultRoot)

    public let root: URL
    public var spoolDir: URL { root.appendingPathComponent("history/spool", isDirectory: true) }
    public var audioDir: URL { root.appendingPathComponent("history/audio", isDirectory: true) }
    public var databaseURL: URL { root.appendingPathComponent("history.sqlite") }
    private let settings: Settings
    private let lock = NSLock()
    private var db: OpaquePointer?

    public init(root: URL, settings: Settings = .shared) {
        self.root = root
        self.settings = settings
    }

    deinit { if let db { sqlite3_close(db) } }

    // MARK: Spool

    /// Writes the audio to the spool before transcription. `privateField` (a password field or an app on the
    /// privacy list) and `history: off` keep everything in memory.
    public func begin(samples: [Float], app: String?, mode: CleanupMode, privateField: Bool, now: Date = Date()) -> Pending {
        let id = Self.newID(now)
        guard settings.string(.history) != "off", !privateField else {
            return Pending(id: id, time: now, app: app, mode: mode, spool: nil)
        }
        do {
            try Self.makePrivateDirectory(spoolDir)
            let wav = spoolDir.appendingPathComponent("\(id).wav")
            try Self.wavData(samples).write(to: wav, options: .atomic)
            let meta = try JSONEncoder().encode(SpoolMeta(id: id, time: now, app: app, mode: mode))
            try meta.write(to: wav.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
            return Pending(id: id, time: now, app: app, mode: mode, spool: wav)
        } catch {
            return Pending(id: id, time: now, app: app, mode: mode, spool: nil)
        }
    }

    /// Saves the transcript and clears the spool (or keeps the audio when `keepAudio` is set).
    @discardableResult
    public func complete(_ pending: Pending, transcript: Transcript, delivery: String, flags: [String] = [],
                         timing: Timing? = nil) -> Row? {
        guard let spool = pending.spool else { return nil }
        defer { Self.removeSpool(spool) }
        guard !transcript.text.isEmpty else { return nil }
        var audioPath: String?
        if settings.snapshot().days(.keepAudio) != nil, (try? Self.makePrivateDirectory(audioDir)) != nil {
            // Kept as 16-bit FLAC, about a quarter of the spool's float WAV. If that fails, keep the WAV itself.
            let flac = audioDir.appendingPathComponent(pending.id + ".flac")
            let kept = audioDir.appendingPathComponent(spool.lastPathComponent)
            if (try? Self.writeFLAC(from: spool, to: flac)) != nil {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: flac.path)
                audioPath = flac.path
            } else {
                try? FileManager.default.removeItem(at: flac)
                if (try? FileManager.default.moveItem(at: spool, to: kept)) != nil { audioPath = kept.path }
            }
        }
        let row = Row(id: pending.id, time: pending.time, app: pending.app, mode: transcript.mode.rawValue,
                      engine: transcript.engine, raw: transcript.raw, text: transcript.text, steps: transcript.steps,
                      audioSeconds: transcript.audioSeconds, totalMs: transcript.totalMs, delivery: delivery,
                      audioPath: audioPath, flags: flags + (transcript.doubtful == nil || flags.contains("doubtful") ? [] : ["doubtful"]),
                      timing: timing)
        do { try insert(row) } catch { return nil }
        prune()
        return row
    }

    /// Copies a recording into a 16-bit FLAC file, a piece at a time so a long dictation never sits in memory twice.
    /// The samples are handed over as 16-bit integers: given floats, the encoder stores 24 bits and saves little.
    static func writeFLAC(from wav: URL, to flac: URL) throws {
        let input = try AVAudioFile(forReading: wav)
        let rate = input.fileFormat.sampleRate
        guard input.processingFormat.channelCount == 1, input.processingFormat.commonFormat == .pcmFormatFloat32,
              let ints = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: false),
              let chunk = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 32_768),
              let out = AVAudioPCMBuffer(pcmFormat: ints, frameCapacity: 32_768) else { throw LarynxError.unreadableAudio }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                                       AVEncoderBitDepthHintKey: 16]
        let output = try AVAudioFile(forWriting: flac, settings: settings, commonFormat: .pcmFormatInt16, interleaved: false)
        var written: AVAudioFramePosition = 0
        while input.framePosition < input.length {
            try input.read(into: chunk)
            let count = Int(chunk.frameLength)
            guard count > 0, let source = chunk.floatChannelData?[0], let target = out.int16ChannelData?[0] else { break }
            for i in 0..<count { target[i] = Int16((max(-1, min(1, source[i])) * 32_767).rounded()) }
            out.frameLength = chunk.frameLength
            try output.write(from: out)
            written += AVAudioFramePosition(count)
        }
        guard written == input.length else { throw LarynxError.unreadableAudio }
    }

    /// Recordings a crash left behind, oldest first. `olderThan` skips files a running dictation is still using.
    public func abandoned(olderThan cutoff: Date) -> [(pending: Pending, samples: [Float])] {
        let files = (try? FileManager.default.contentsOfDirectory(at: spoolDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "wav" }.compactMap { wav in
            let modified = (try? wav.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
            guard modified < cutoff else { return nil }
            let metaURL = wav.deletingPathExtension().appendingPathExtension("json")
            let meta = (try? Data(contentsOf: metaURL)).flatMap { try? JSONDecoder().decode(SpoolMeta.self, from: $0) }
            guard let samples = try? loadAudioFile(wav), !samples.isEmpty else {
                // Unreadable audio would be retried forever; set it aside where a person can still find it.
                try? FileManager.default.moveItem(at: wav, to: wav.appendingPathExtension("unreadable"))
                return nil
            }
            let id = meta?.id ?? wav.deletingPathExtension().lastPathComponent
            return (Pending(id: id, time: meta?.time ?? modified, app: meta?.app, mode: meta?.mode ?? .standard, spool: wav), samples)
        }.sorted { $0.pending.time < $1.pending.time }
    }

    /// Drops a spooled recording without saving anything (it was a tap, heard nothing, or was cancelled).
    public func discard(_ pending: Pending) { if let spool = pending.spool { Self.removeSpool(spool) } }

    // MARK: Database

    public func recent(limit: Int = 10) -> [Row] { (try? query(nil, limit: limit)) ?? [] }

    /// Adds a flag to a saved dictation ("undone" after "scratch that").
    public func addFlag(_ flag: String, to id: String) {
        try? withDB { db in
            try exec(db, "UPDATE dictations SET flags = CASE WHEN flags IS NULL OR flags = '' THEN ? ELSE flags || ',' || ? END WHERE id = ? AND (',' || COALESCE(flags, '') || ',') NOT LIKE ?",
                     [flag, flag, id, "%," + flag + ",%"])
        }
    }

    /// Records what dictation `id` should have said (`source`: "edit" or "repeat"). Kept only as long as the dictation.
    public func recordCorrection(id: String, text: String, source: String, now: Date = Date()) {
        try? withDB { db in
            try exec(db, "INSERT OR REPLACE INTO corrections (id, text, source, time) SELECT ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM dictations WHERE id = ?)",
                     [id, text, source, now.timeIntervalSince1970, id])
        }
    }

    /// Every recorded correction, by dictation id.
    public func corrections() -> [String: (text: String, source: String)] {
        var out: [String: (text: String, source: String)] = [:]
        try? withDB { db in
            let statement = try prepare(db, "SELECT id, text, source FROM corrections", [])
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                func string(_ i: Int32) -> String? { sqlite3_column_text(statement, i).map { String(cString: $0) } }
                if let id = string(0), let text = string(1) { out[id] = (text, string(2) ?? "") }
            }
        }
        return out
    }

    /// Full-text search; every word must match (prefixes count: "deplo" finds "deploy").
    public func search(_ text: String, limit: Int = 50) -> [Row] { (try? query(text, limit: limit)) ?? [] }

    /// Deletes text older than `historyDays` and kept audio older than `keepAudio` days.
    public func prune(now: Date = Date()) {
        let snapshot = settings.snapshot()
        let cutoff = now.addingTimeInterval(-Double(snapshot.days(.historyDays) ?? 30) * 86_400)
        try? withDB { db in
            try exec(db, "DELETE FROM dictations_fts WHERE id IN (SELECT id FROM dictations WHERE time < ?)", [cutoff.timeIntervalSince1970])
            try exec(db, "DELETE FROM dictations WHERE time < ?", [cutoff.timeIntervalSince1970])
            try exec(db, "DELETE FROM corrections WHERE id NOT IN (SELECT id FROM dictations)")
        }
        let audioCutoff = now.addingTimeInterval(-Double(snapshot.days(.keepAudio) ?? 0) * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if modified < audioCutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    func insert(_ row: Row) throws {
        let steps = String(decoding: try JSONEncoder().encode(row.steps), as: UTF8.self)
        let timing = try row.timing.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try withDB { db in
            try exec(db, """
                INSERT OR REPLACE INTO dictations (id, time, app, mode, engine, raw, text, steps, audioSeconds, totalMs, delivery, audioPath, flags, timing)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [row.id, row.time.timeIntervalSince1970, row.app, row.mode, row.engine, row.raw, row.text, steps,
                      row.audioSeconds, row.totalMs, row.delivery, row.audioPath, row.flags.joined(separator: ","), timing])
            try exec(db, "DELETE FROM dictations_fts WHERE id = ?", [row.id])
            try exec(db, "INSERT INTO dictations_fts (id, text) VALUES (?, ?)", [row.id, row.text])
        }
    }

    private func query(_ search: String?, limit: Int) throws -> [Row] {
        var rows: [Row] = []
        try withDB { db in
            let columns = "d.id, d.time, d.app, d.mode, d.engine, d.raw, d.text, d.steps, d.audioSeconds, d.totalMs, d.delivery, d.audioPath, d.flags, d.timing"
            let match = search.map(Self.ftsQuery) ?? ""
            let sql = match.isEmpty
                ? "SELECT \(columns) FROM dictations d ORDER BY d.time DESC LIMIT ?"
                : "SELECT \(columns) FROM dictations_fts f JOIN dictations d ON d.id = f.id WHERE dictations_fts MATCH ? ORDER BY d.time DESC LIMIT ?"
            let statement = try prepare(db, sql, match.isEmpty ? [limit] : [match, limit])
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                func string(_ i: Int32) -> String? { sqlite3_column_text(statement, i).map { String(cString: $0) } }
                let steps = string(7).flatMap { try? JSONDecoder().decode([Step].self, from: Data($0.utf8)) } ?? []
                rows.append(Row(id: string(0) ?? "", time: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                                app: string(2), mode: string(3) ?? "", engine: string(4) ?? "", raw: string(5) ?? "",
                                text: string(6) ?? "", steps: steps, audioSeconds: sqlite3_column_double(statement, 8),
                                totalMs: Int(sqlite3_column_int64(statement, 9)), delivery: string(10) ?? "",
                                audioPath: string(11), flags: (string(12) ?? "").split(separator: ",").map(String.init),
                                timing: string(13).flatMap { try? JSONDecoder().decode(Timing.self, from: Data($0.utf8)) }))
            }
        }
        return rows
    }

    /// Each word becomes a quoted prefix term, so punctuation in a search can't break FTS syntax.
    static func ftsQuery(_ text: String) -> String {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"*" }
            .joined(separator: " ")
    }

    // MARK: SQLite plumbing

    public enum HistoryError: Error, CustomStringConvertible {
        case sqlite(String)
        public var description: String { if case .sqlite(let m) = self { return "history database: \(m)" }; return "history" }
    }

    private func withDB(_ body: (OpaquePointer) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        if db == nil {
            try Self.makePrivateDirectory(root)
            var handle: OpaquePointer?
            guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                  let handle else {
                let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
                sqlite3_close(handle)
                throw HistoryError.sqlite(message)
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
            sqlite3_busy_timeout(handle, 2000)
            try exec(handle, "PRAGMA journal_mode = WAL")
            try exec(handle, """
                CREATE TABLE IF NOT EXISTS dictations (
                    id TEXT PRIMARY KEY, time REAL NOT NULL, app TEXT, mode TEXT, engine TEXT, raw TEXT, text TEXT,
                    steps TEXT, audioSeconds REAL, totalMs INTEGER, delivery TEXT, audioPath TEXT, flags TEXT, timing TEXT)
                """)
            try exec(handle, "CREATE INDEX IF NOT EXISTS dictations_time ON dictations(time)")
            try exec(handle, "CREATE VIRTUAL TABLE IF NOT EXISTS dictations_fts USING fts5(id UNINDEXED, text)")
            // What a dictation should have said, when the user fixed it: an edit in the field or a repeat with a word
            // changed. The golden set (`larynx golden`) takes its reference texts from here.
            try exec(handle, "CREATE TABLE IF NOT EXISTS corrections (id TEXT PRIMARY KEY, text TEXT NOT NULL, source TEXT, time REAL)")
            // Version 2 (Nov 12, 2026): the time split and delivery reason of each dictation (R1).
            if !Self.hasColumn(handle, table: "dictations", column: "timing") {
                try exec(handle, "ALTER TABLE dictations ADD COLUMN timing TEXT")
            }
            try exec(handle, "PRAGMA user_version = 2")
            db = handle
        }
        try body(db!)
    }

    private static func hasColumn(_ db: OpaquePointer, table: String, column: String) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1), String(cString: name) == column { return true }
        }
        return false
    }

    private func prepare(_ db: OpaquePointer, _ sql: String, _ values: [Any?]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw HistoryError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case let v as String: sqlite3_bind_text(statement, index, v, -1, transient)
            case let v as Int: sqlite3_bind_int64(statement, index, Int64(v))
            case let v as Double: sqlite3_bind_double(statement, index, v)
            default: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func exec(_ db: OpaquePointer, _ sql: String, _ values: [Any?] = []) throws {
        let statement = try prepare(db, sql, values)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw HistoryError.sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    // MARK: Files

    static func newID(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: date) + "-" + UUID().uuidString.prefix(6).lowercased()
    }

    static func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    static func removeSpool(_ wav: URL) {
        try? FileManager.default.removeItem(at: wav)
        try? FileManager.default.removeItem(at: wav.deletingPathExtension().appendingPathExtension("json"))
    }

    /// 16 kHz mono 32-bit float WAV: playable anywhere and readable by `loadAudioFile`.
    static func wavData(_ samples: [Float]) -> Data {
        let dataBytes = UInt32(samples.count * 4)
        var d = Data(capacity: 44 + Int(dataBytes))
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(3); u16(1)  // IEEE float, mono
        u32(UInt32(Recorder.sampleRate)); u32(UInt32(Recorder.sampleRate) * 4); u16(4); u16(32)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        samples.withUnsafeBufferPointer { d.append(UnsafeBufferPointer(start: UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: UInt8.self), count: Int(dataBytes))) }
        return d
    }
}

extension History.Row {
    /// A row made by hand (the History window's layout snapshot uses made-up ones). Real rows come from `complete`.
    public init(id: String, time: Date, app: String?, text: String, audioSeconds: Double, delivery: String = "inserted",
                flags: [String] = [], audioPath: String? = nil) {
        self.init(id: id, time: time, app: app, mode: "standard", engine: "ultra", raw: text, text: text, steps: [],
                  audioSeconds: audioSeconds, totalMs: 0, delivery: delivery, audioPath: audioPath, flags: flags)
    }
}
