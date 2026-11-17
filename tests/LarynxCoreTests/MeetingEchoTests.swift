import Foundation
import Testing
@testable import LarynxCore

/// The call heard through the speakers and picked up again by the microphone (MeetingEcho), and the hint that tells
/// the notes model you mostly listened. Every sentence here is made up.
struct MeetingEchoTests {
    func call(_ start: Double, _ end: Double, _ text: String) -> MeetingSegment { MeetingSegment(speaker: "On the call", start: start, end: end, text: text) }
    func you(_ start: Double, _ end: Double, _ text: String) -> MeetingSegment { MeetingSegment(speaker: "You", start: start, end: end, text: text) }

    @Test func aPieceOfTheCallHeardWhileItPlaysIsAnEcho() {
        let segs = [call(0, 8, "The new warehouse lease starts on March first and the movers come on Friday."),
                    you(3, 5, "Lease starts on March first.")]
        #expect(MeetingEcho.remove(segs) == [segs[0]])
    }

    @Test func aSlightlyMisheardEchoIsStillAnEcho() {
        let segs = [call(0, 9, "Coreweave and Nimbus have both signed on for the larger racks this quarter."),
                    you(2, 4, "Carweave and Nimbus have signed.")]
        #expect(MeetingEcho.remove(segs) == [segs[0]])
    }

    @Test func aNearCopyRightAfterTheCallLineIsAnEcho() {
        let segs = [call(0, 5, "Subscriptions grew forty percent this year."), you(5.6, 7.5, "grew forty percent this year")]
        #expect(MeetingEcho.remove(segs) == [segs[0]])
    }

    @Test func aReplyThatReusesTheCallsWordsStays() {
        let segs = [call(0, 4, "The standard paper saves us about two thousand dollars."),
                    you(4.6, 7, "Let's stay with the standard paper then.")]
        #expect(MeetingEcho.remove(segs) == segs)
    }

    @Test func aShortQuestionBackStays() {
        let segs = [call(0, 3, "The kitchen tiles go in next week."), you(3.5, 4.4, "And the bathroom?")]
        #expect(MeetingEcho.remove(segs) == segs)
        let back = [call(0, 3, "Sales are up forty percent."), you(3.4, 4.2, "Forty percent?")]
        #expect(MeetingEcho.remove(back) == back)
    }

    @Test func talkingOverTheCallStays() {
        let segs = [call(0, 10, "Next we'll go through the budget for each team, starting with design and then support."),
                    you(4, 5.5, "Sorry, can you say that again?")]
        #expect(MeetingEcho.remove(segs) == segs)
    }

    @Test func withoutTheCallNothingChanges() {
        let segs = [you(0, 2, "Remind me to call the plumber."), you(3, 5, "Remind me to call the plumber.")]
        #expect(MeetingEcho.remove(segs) == segs)
    }

    func meeting(_ segs: [MeetingSegment]) -> Meeting { Meeting(id: "t", started: Date(timeIntervalSince1970: 0), duration: 600, segments: segs) }
    let longCallLine = Array(repeating: "Our numbers for the quarter came in ahead of plan in every region we serve.", count: 12).joined(separator: " ")

    @Test func listeningToATalkGetsTheHint() {
        let m = meeting([call(0, 300, longCallLine), you(100, 102, "Wow, that's big.")])
        let note = MeetingSummarizer.listeningNote(m)
        #expect(note == "You said 2% of the words in this meeting.")
        #expect(ClaudeNotes.prompt(for: m).system.contains("You said 2% of the words"))
        #expect(ClaudeNotes.prompt(for: m).system.contains("mostly listened"))
    }

    @Test func aMeetingYouTookPartInGetsNoHint() {
        let m = meeting([call(0, 300, longCallLine), you(300, 400, longCallLine)])
        #expect(MeetingSummarizer.listeningNote(m) == nil)
        #expect(!ClaudeNotes.prompt(for: m).system.contains("of the words in this meeting"))
        let short = meeting([call(0, 5, "Hello there."), you(6, 7, "Hi.")])
        #expect(MeetingSummarizer.listeningNote(short) == nil)
    }
}
