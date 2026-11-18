import Foundation
import Testing
@testable import LarynxCore

/// The meeting-mode cases the Mac and Windows apps share (tests/meeting-cases.json). The Windows tests read the same
/// file (windows/src/meeting.rs, mod shared_cases), so a rule changed on one side and not the other fails here or there.
struct MeetingCasesTests {
    struct Notes: Decodable {
        struct Item: Decodable { var task: String; var owner: String; var due: String }
        var title: String
        var summary: [String]
        var decisions: [String]
        var actionItems: [Item]
        var openQuestions: [String]
        var generated: GeneratedNotes {
            GeneratedNotes(title: title, summary: summary, decisions: decisions,
                           actionItems: actionItems.map { .init(task: $0.task, owner: $0.owner, due: $0.due) }, openQuestions: openQuestions)
        }
    }
    struct Case: Decodable {
        var name: String?
        var segments: [MeetingSegment]?
        var duration: Double?
        var keep: [Int]?
        var note: String?
        var names: [String]?
        var speakers: [String]?
        var text: String?
        var numbers: [String]?
        var notes: Notes?
        var expect: Notes?
        var system: String?
        var transcript: String?
    }
    struct File: Decodable {
        var echo, listening, names, naming, numbers, verify, prompt: [Case]
        var clock: [[ClockValue]]
    }
    enum ClockValue: Decodable {
        case seconds(Double), text(String)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) { self = .seconds(d) } else { self = .text(try c.decode(String.self)) }
        }
    }

    static let file: File = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try! JSONDecoder().decode(File.self, from: Data(contentsOf: root.appendingPathComponent("tests/meeting-cases.json")))
    }()

    func meeting(_ c: Case) -> Meeting {
        Meeting(id: "t", started: Date(timeIntervalSince1970: 0), duration: c.duration ?? 60, segments: c.segments ?? [])
    }

    @Test func echo() {
        for c in Self.file.echo {
            let segs = c.segments!
            #expect(MeetingEcho.remove(segs) == c.keep!.map { segs[$0] }, "\(c.name!)")
        }
    }

    @Test func listening() {
        for c in Self.file.listening { #expect(MeetingSummarizer.listeningNote(meeting(c)) == c.note, "\(c.name!)") }
    }

    @Test func names() {
        for c in Self.file.names { #expect(meeting(c).addressedNames == c.names!, "\(c.name!)") }
        for c in Self.file.naming { #expect(meeting(c).namingTheCall().speakers == c.speakers!, "\(c.name!)") }
    }

    @Test func numbersAndClock() {
        for c in Self.file.numbers { #expect(MeetingSummarizer.numbers(c.text!) == Set(c.numbers!), "\(c.text!)") }
        for pair in Self.file.clock {
            guard case .seconds(let s) = pair[0], case .text(let t) = pair[1] else { Issue.record("bad clock case"); continue }
            #expect(Meeting.clock(s) == t)
        }
    }

    @Test func verify() {
        for c in Self.file.verify {
            let got = MeetingSummarizer.verify(c.notes!.generated, against: meeting(c))
            #expect(got.asText == c.expect!.generated.asText, "\(c.name!)")
        }
    }

    @Test func prompt() {
        for c in Self.file.prompt {
            let (system, user) = ClaudeNotes.prompt(for: meeting(c))
            #expect(system == c.system!, "\(c.name!)\n--- got ---\n\(system)")
            #expect(user.contains("<transcript>\n\(c.transcript!)\n</transcript>"), "\(c.name!)\n--- got ---\n\(user)")
        }
    }
}
