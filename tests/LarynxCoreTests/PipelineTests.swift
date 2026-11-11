import Foundation
import Testing
@testable import LarynxCore

private func transcript(_ text: String, mode: CleanupMode = .standard) -> Transcript {
    Transcript(text: text, raw: text, engine: "fixture", mode: mode, audioSeconds: 1,
               asrMs: 2, rewriteMs: 0, totalMs: 0, rewrite: "off", rewritten: false)
}

@Test func pipelinePreservesExistingTextContract() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("tests/cases.json"))
    let cases = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let text = try #require(cases["text"] as? [[String: String]])
    let unchanged = try #require(cases["mustNotChange"] as? [[String: String]])
    for c in text {
        let input = try #require(c["in"])
        let modeName = try #require(c["mode"])
        let mode = try #require(CleanupMode(rawValue: modeName))
        let result = await Pipeline().run(transcript(input, mode: mode), context: .init(rewrite: false))
        #expect(result.text == c["expect"], "\(c["id"] ?? "")")
        #expect(result.raw == input)
    }
    for c in unchanged {
        let input = try #require(c["in"])
        for mode in [CleanupMode.standard, .ai, .correspondence] {
            let result = await Pipeline().run(transcript(input, mode: mode), context: .init(rewrite: false))
            #expect(result.text == input, "\(c["id"] ?? "") \(mode.rawValue)")
        }
    }
}

@Test func pipelineUsesExistingOrderAndBypassesLiteralSnippets() async {
    let context = Pipeline.Context(rewrite: false, snippets: ["my link": "the the prisma"],
                                   dictionary: ["lynx": "prisma"], caseTerms: ["Prisma"])
    let result = await Pipeline().run(transcript("the the lynx"), context: context)
    #expect(result.text == "The Prisma")
    #expect(result.steps.map(\.stage) == ["snippet", "dictionary", "vocabularyCase", "tidy", "rewrite"])
    #expect(result.steps[1].before == "the the lynx")
    #expect(result.steps[1].after == "the the prisma")
    #expect(result.steps[2].after == "the the Prisma")
    let snippet = await Pipeline().run(transcript("Insert my link!"), context: context)
    #expect(snippet.text == "the the prisma")
    #expect(snippet.snippet == "my link")
    #expect(snippet.rewrite == "snippet")
    #expect(snippet.steps.count == 1)
    let verbatim = await Pipeline().run(transcript("the the lynx"), context: .init(tidy: false, rewrite: false, dictionary: context.dictionary))
    #expect(verbatim.text == "the the lynx")
    #expect(verbatim.steps.allSatisfy { !$0.applied })
}

@Test func shadowProposalsNeverFeedLaterStages() async {
    let settings = Settings.Snapshot(values: [.dictionaryStage: "shadow", .vocabularyCaseStage: "off"])
    let result = await Pipeline().run(transcript("the the lynx"), context: .init(rewrite: false,
        dictionary: ["lynx": "Prisma"], settings: settings))
    #expect(result.text == "The lynx")
    #expect(result.steps[1].after == "the the Prisma")
    #expect(!result.steps[1].applied)
    #expect(result.steps[2].before == "the the lynx")
    #expect(result.steps[2].after == "the the lynx")
    #expect(!result.steps[2].applied)
    let snippet = await Pipeline().run(transcript("my link"), context: .init(rewrite: false,
        snippets: ["my link": "expanded"], settings: .init(values: [.snippetStage: "shadow"])))
    #expect(snippet.text == "My link")
    #expect(snippet.snippet == nil)
    #expect(snippet.steps.count == 5)
    #expect(snippet.steps[0].after == "expanded")
}

@Test func disabledStagesAreNotInvokedAndShadowRewriteKeepsText() async {
    let forbidden = Pipeline.Stage(name: "rewrite", setting: .rewriteStage) { input, _ in
        Issue.record("disabled stage was invoked")
        return input
    }
    let off = await Pipeline(stages: [forbidden]).run(transcript("Original"), context: .init(settings: .init(values: [.rewriteStage: "off"])))
    #expect(off.text == "Original")
    #expect(off.steps == [Step(stage: "rewrite", before: "Original", after: "Original", applied: false)])
    let rewrite = Pipeline.Stage(name: "rewrite", setting: .rewriteStage) { input, context in
        #expect(context.forceRewrite)
        var result = input
        result.text = "Candidate"
        result.rewritten = true
        result.rewrite = "forced"
        result.rewriteMs = 17
        return result
    }
    let shadow = await Pipeline(stages: [rewrite]).run(transcript("Original"), context: .init(forceRewrite: true, settings: .init(values: [.rewriteStage: "shadow"])))
    #expect(shadow.text == "Original")
    #expect(!shadow.rewritten)
    #expect(shadow.rewrite == "shadow: forced")
    #expect(shadow.rewriteMs == 17)
    #expect(shadow.steps.first?.after == "Candidate")
    #expect(shadow.steps.first?.applied == false)
}

@Test func sessionsFinishIndependentlyAndRejectInvalidTransitions() {
    var first = SessionState()
    let transition0 = first.finish()
    #expect(!transition0)
    let transition1 = first.deliver()
    #expect(!transition1)
    let transition2 = first.start()
    #expect(transition2)
    let transition3 = first.start()
    #expect(!transition3)
    let transition4 = first.deliver()
    #expect(!transition4)
    let transition5 = first.finish()
    #expect(transition5)
    var next = SessionState()
    let transition6 = next.start()
    #expect(transition6)
    let transition7 = first.deliver()
    #expect(transition7)
    first.reset()
    #expect(first.phase == .idle)
    #expect(next.phase == .recording)
    next.reset()
    let transition8 = next.finish()
    #expect(!transition8)
    let transition9 = next.start()
    #expect(transition9)
}
