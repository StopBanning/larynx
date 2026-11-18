import Foundation

/// "Send a Report…": one plain text file a person can send when Larynx misbehaves, so whoever helps them gets facts
/// instead of "it doesn't work". The Windows app writes the same file (windows/src/report.rs). What's in it is said at
/// the top, and it never holds the words of a dictation, a meeting's transcript or notes, or a key: only versions, the
/// Mac, its microphones, permissions, timings and errors from the log, and the shape of recent meetings.
public enum BugReport {
    public static let header = """
        Larynx report

        This file is for the person helping you with Larynx. It holds the app's version, this Mac's details and
        microphones, the app's log (timings and errors) and the length of your recent meetings. It does not hold
        anything you said or dictated, any meeting transcript or summary, or your Claude key. Read it before you
        send it if you like.
        """

    /// The report. `app` and `computer` are free text gathered by the app; `log` is ~/Library/Logs/Larynx.log.
    public static func build(app: String, computer: String, log: String, meetings: [Meeting], lines: Int = 400, home: String = NSHomeDirectory()) -> String {
        var out = [header, "", "== Larynx", app.trimmingCharacters(in: .whitespacesAndNewlines), "",
                   "== This Mac", computer.trimmingCharacters(in: .whitespacesAndNewlines), "",
                   "== Recent meetings (\(meetings.count))"]
        if meetings.isEmpty { out.append("none") }
        for m in meetings {
            let yours = m.segments.filter { $0.speaker == "You" }.count
            let notes = m.notes.map { _ in "notes written" } ?? "no notes"
            out.append("\(m.id)  \(Int((m.duration / 60).rounded())) min, \(m.segments.count) lines (\(yours) yours), \(notes)")
        }
        out.append("")
        let all = log.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let tail = all.suffix(lines)
        out.append("== Log (last \(tail.count) of \(all.count) lines)")
        out += tail.map { scrub($0) }
        var text = out.joined(separator: "\n") + "\n"
        if !home.isEmpty { text = text.replacingOccurrences(of: home, with: "~") }
        return text
    }

    /// Log lines that name words (what a correction taught Larynx) keep only their start; anything quoted is cut.
    static func scrub(_ line: String) -> String {
        for marker in ["learned from your fix:", "heard:", "typed:", "meant:"] {
            if let r = line.range(of: marker) { return line[..<r.upperBound] + " (words left out)" }
        }
        if let q = line.firstIndex(where: { "\"“”'‘’".contains($0) }), line.contains(" ") {
            return String(line[..<q]) + "(left out)"
        }
        return line
    }

    /// A log past `max` bytes keeps its newer half, cut at a line break; nil when it is small enough.
    public static func trimmed(_ log: String, max: Int) -> String? {
        let bytes = Array(log.utf8)
        guard bytes.count > max else { return nil }
        var rest = bytes[(bytes.count - max / 2)...]
        if let nl = rest.firstIndex(of: 0x0A) { rest = rest[(nl + 1)...] }
        return String(decoding: rest, as: UTF8.self)
    }
}
