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
    public func complete(_ pending: Pending, transcript: Transcript, delivery: String, flags: [String] = []) -> Row? {
        guard let spool = pending.spool else { return nil }
        defer { Self.removeSpool(spool) }
        guard !transcript.text.isEmpty else { return nil }
        var audioPath: String?
        if settings.snapshot().days(.keepAudio) != nil, (try? Self.makePrivateDirectory(audioDir)) != nil {
            let kept = audioDir.appendingPathComponent(spool.lastPathComponent)
            if (try? FileManager.default.moveItem(at: spool, to: kept)) != nil { audioPath = kept.path }
        }
        let row = Row(id: pending.id, time: pending.time, app: pending.app, mode: transcript.mode.rawValue,
                      engine: transcript.engine, raw: transcript.raw, text: transcript.text, steps: transcript.steps,
                      audioSeconds: transcript.audioSeconds, totalMs: transcript.totalMs, delivery: delivery,
                      audioPath: audioPath, flags: flags)
        do { try insert(row) } catch { return nil }
        prune()
        return row
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

    /// Full-text search; every word must match (prefixes count: "deplo" finds "deploy").
    public func search(_ text: String, limit: Int = 50) -> [Row] { (try? query(text, limit: limit)) ?? [] }

    /// Deletes text older than `historyDays` and kept audio older than `keepAudio` days.
    public func prune(now: Date = Date()) {
        let snapshot = settings.snapshot()
        let cutoff = now.addingTimeInterval(-Double(snapshot.days(.historyDays) ?? 30) * 86_400)
        try? withDB { db in
            try exec(db, "DELETE FROM dictations_fts WHERE id IN (SELECT id FROM dictations WHERE time < ?)", [cutoff.timeIntervalSince1970])
            try exec(db, "DELETE FROM dictations WHERE time < ?", [cutoff.timeIntervalSince1970])
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
        try withDB { db in
            try exec(db, """
                INSERT OR REPLACE INTO dictations (id, time, app, mode, engine, raw, text, steps, audioSeconds, totalMs, delivery, audioPath, flags)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [row.id, row.time.timeIntervalSince1970, row.app, row.mode, row.engine, row.raw, row.text, steps,
                      row.audioSeconds, row.totalMs, row.delivery, row.audioPath, row.flags.joined(separator: ",")])
            try exec(db, "DELETE FROM dictations_fts WHERE id = ?", [row.id])
            try exec(db, "INSERT INTO dictations_fts (id, text) VALUES (?, ?)", [row.id, row.text])
        }
    }

    private func query(_ search: String?, limit: Int) throws -> [Row] {
        var rows: [Row] = []
        try withDB { db in
            let columns = "d.id, d.time, d.app, d.mode, d.engine, d.raw, d.text, d.steps, d.audioSeconds, d.totalMs, d.delivery, d.audioPath, d.flags"
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
                                audioPath: string(11), flags: (string(12) ?? "").split(separator: ",").map(String.init)))
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
                    steps TEXT, audioSeconds REAL, totalMs INTEGER, delivery TEXT, audioPath TEXT, flags TEXT)
                """)
            try exec(handle, "CREATE INDEX IF NOT EXISTS dictations_time ON dictations(time)")
            try exec(handle, "CREATE VIRTUAL TABLE IF NOT EXISTS dictations_fts USING fts5(id UNINDEXED, text)")
            try exec(handle, "PRAGMA user_version = 1")
            db = handle
        }
        try body(db!)
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
