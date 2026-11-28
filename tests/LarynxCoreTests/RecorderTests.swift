import Foundation
import Testing
@testable import LarynxCore

/// A second of room noise, then `speech` seconds of a voice-loud tone, then `pause` seconds of room noise.
private func clip(speech: Double, pause: Double) -> [Float] {
    let rate = Recorder.sampleRate
    var rng = SystemRandomNumberGenerator()
    let noise: (Int) -> [Float] = { n in (0..<n).map { _ in Float.random(in: -0.003...0.003, using: &rng) } }
    let tone = (0..<Int(rate * speech)).map { Float(sin(Double($0) * 0.06) * 0.15) }
    return noise(Int(rate)) + tone + noise(Int(rate * pause))
}

@Test func speechRunningIntoKeyUpKeepsListeningAndAPauseDoesNot() {
    #expect(Recorder.speechAtEnd(clip(speech: 1.0, pause: 0)))        // word still being said as the key comes up
    #expect(!Recorder.speechAtEnd(clip(speech: 1.0, pause: 0.3)))     // finished, then a pause: stop at once
    #expect(!Recorder.speechAtEnd(clip(speech: 0, pause: 1.0)))       // nothing said
    #expect(!Recorder.speechAtEnd([Float](repeating: 0.2, count: 400))) // too short to judge
}

@Test func aPressBeforeTheLastRecordingIsCollectedGetsItsOwn() async throws {
    let r = Recorder()
    r.warmSeconds = { 60 }  // no cool-down during the test
    let first = [Float](repeating: 0.001, count: 16_000), second = [Float](repeating: 0.002, count: 8_000)
    r.beginForTest(); r.appendForTest(first)
    r.willStop()            // key up: the collection task hasn't run yet
    try r.start()           // the next press arrives first
    r.appendForTest(second)
    let a = await r.stopAfterTail()
    #expect(a.samples == first)
    #expect(r.isRecording)  // the new dictation is still recording
    let b = await r.stopAfterTail()
    #expect(b.samples == second)
    #expect(r.stop().isEmpty)  // handed over once: never the same audio twice
}
