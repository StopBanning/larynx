import Foundation
import Testing
@testable import LarynxCore

/// "Send a Report…": nothing said, no notes, no names a correction taught, no home folder. Every sentence is made up.
struct BugReportTests {
    let meeting = Meeting(id: "20261118-091500", started: Date(timeIntervalSince1970: 1_800_000_000), duration: 1_250,
                          segments: [MeetingSegment(speaker: "You", start: 0, end: 2, text: "The gate code is four four one two."),
                                     MeetingSegment(speaker: "On the call", start: 2, end: 3, text: "Got it, thanks.")])

    @Test func nothingSaidOrSecretGetsIn() {
        let log = """
            larynx: recording... [com.apple.Notes] mic 12 ms
            larynx: 140 ms [standard com.apple.Notes] inserted, rewrite: not needed (0 ms), 6 words, 20261118-091501-000-abc123; mic 12 tail 0 wait 30 asr 90 clean 2
            larynx: learned from your fix: Marisol -> Marissa
            larynx: could not open "/Users/someone/Desktop/gate code.txt"
            larynx: Error Domain=com.apple.coreaudio.avfaudio Code=-10868
            """
        var m = meeting
        m.notes = MeetingNotes(title: "Gate code for the crew", summary: ["The gate code is 4412."], decisions: [], actionItems: [], openQuestions: [], model: "claude", seconds: 9)
        let r = BugReport.build(app: "Larynx 1.0", computer: "macOS 26", log: log, meetings: [m], home: "/Users/someone")
        for secret in ["gate code", "4412", "four four", "Gate code for the crew", "Got it", "Marisol", "Marissa", "/Users/someone"] {
            #expect(!r.contains(secret), "\(secret) leaked:\n\(r)")
        }
        #expect(r.contains("mic 12 ms") && r.contains("asr 90") && r.contains("Code=-10868"))
        #expect(r.contains("learned from your fix: (words left out)"))
        #expect(r.contains("20261118-091500  21 min, 2 lines (1 yours), notes written"))
        #expect(r.hasPrefix("Larynx report"))
    }

    @Test func onlyTheEndOfALongLog() {
        let log = (0..<1000).map { "larynx: tap \($0)" }.joined(separator: "\n")
        let r = BugReport.build(app: "", computer: "", log: log, meetings: [], home: "")
        #expect(r.contains("== Log (last 400 of 1000 lines)"))
        #expect(r.contains("tap 999") && r.contains("tap 600\n") && !r.contains("tap 599\n"))
        #expect(r.contains("== Recent meetings (0)\nnone"))
    }

    @Test func aBigLogIsTrimmedAtALine() {
        let log = (0..<100).map { "line \($0)\n" }.joined()
        #expect(BugReport.trimmed(log, max: 10_000) == nil)
        let t = BugReport.trimmed(log, max: 200)!
        #expect(t.utf8.count <= 100 && t.hasPrefix("line ") && t.hasSuffix("line 99\n"))
    }
}
