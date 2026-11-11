import Foundation
import Testing
@testable import LarynxCore

private func legacyFixture() throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent("tests/fixtures/serve-before-transcript.json"))
}

@Test func legacyServeFieldsSurviveTypedRoundTrip() throws {
    let data = try legacyFixture()
    let legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let transcript = try JSONDecoder().decode(Transcript.self, from: data)
    let encoded = try transcript.jsonObject()
    for (key, value) in legacy where key != "event" && key != "id" {
        let actual = try #require(encoded[key], "missing legacy field \(key)")
        #expect((actual as AnyObject).isEqual(value), "changed legacy field \(key)")
    }
    #expect(transcript.mode == .standard)
    #expect(transcript.steps.isEmpty)
    #expect(transcript.confidence == nil)
    #expect(encoded["steps"] is [Any])
    #expect(encoded["snippet"] == nil)
    #expect(encoded["pasted"] == nil)
}

@Test func transcriptRetainsStepsSnippetAndCopyFailure() throws {
    var transcript = try JSONDecoder().decode(Transcript.self, from: legacyFixture())
    transcript.text = "Hello 👋\nSecond line."
    transcript.snippet = "my greeting"
    transcript.rewrite = "snippet"
    transcript.confidence = 0.875
    transcript.steps = [Step(stage: "example", before: transcript.raw, after: transcript.text, applied: false)]
    transcript.delivered = "copied"
    transcript.pasted = false
    transcript.pasteError = "No focused field"
    let data = try JSONEncoder().encode(transcript)
    #expect(try JSONDecoder().decode(Transcript.self, from: data) == transcript)
    let object = try transcript.jsonObject()
    #expect(object["snippet"] as? String == "my greeting")
    #expect(object["pasted"] as? Bool == false)
    #expect(object["pasteError"] as? String == "No focused field")
    #expect(object["confidence"] as? Double == 0.875)
    let steps = try #require(object["steps"] as? [[String: Any]])
    #expect(steps.first?["applied"] as? Bool == false)
}

@Test func coreExportAndCleanerGuardStayCompatible() {
    // Importing LarynxCore alone continues to expose the extracted public text APIs.
    #expect(Cleaner.guardProblem(original: "Please send the report.", edited: "") == "empty")
    #expect(Cleaner.guardProblem(original: "Please send the report.", edited: "Please send the report.") == nil)
    #expect(Tidy.apply("the the report", mode: .standard) == "The report")
    #expect(Dictionary.apply("Keep going.", map: [:]) == "Keep going.")
}
