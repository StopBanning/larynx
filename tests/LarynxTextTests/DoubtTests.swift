import Testing
@testable import LarynxText

private let english: Set<String> = ["book", "the", "room", "for", "compact", "call", "rome", "bus", "presume", "glass",
                                    "is", "fine", "grab", "a", "quick", "look"]
private func known(_ w: String) -> Bool { english.contains(w) }

@Test func veryLowConfidenceWordsAreDoubtful() {
    let words: [(word: String, confidence: Float)] = [("Book", 1), ("the", 1), ("room", 1), ("for", 1), ("uh", 0.2), ("Compaq", 0.51), ("Robus?", 0.34)]
    #expect(Doubt.words(words, finalText: "Book the room for Compaq Robus?", isKnown: known) == ["Robus"])
    // A filler is never "doubtful", even at low confidence.
    #expect(!Doubt.words(words, finalText: "Book the room for uh Compaq", isKnown: known).contains("uh"))
}

@Test func unknownLowercaseWordsAreDoubtfulSoonerButNamesAreNot() {
    let words: [(word: String, confidence: Float)] = [("Grab", 1), ("a", 1), ("quick", 1), ("lixi", 0.7)]
    #expect(Doubt.words(words, finalText: "Grab a quick lixi.", isKnown: known) == ["lixi"])
    // Confident enough: left alone.
    #expect(Doubt.words([("lixi", 0.9)], finalText: "lixi", isKnown: known).isEmpty)
    // A capitalized unknown word is a name, not a mishearing, unless the model was very unsure.
    #expect(Doubt.words([("Priya", 0.6)], finalText: "Priya", isKnown: known).isEmpty)
}

@Test func aWordTheDictionaryAlreadyReplacedIsNoLongerInDoubt() {
    let words: [(word: String, confidence: Float)] = [("call", 1), ("the", 1), ("Robus", 0.34)]
    #expect(Doubt.words(words, finalText: "call the Rome bus", isKnown: known).isEmpty)
}

@Test func scratchThatAloneIsAnUndoButNotInsideASentence() {
    for t in ["Scratch that.", "scratch that", "Undo that!", "Delete that."] { #expect(VoiceCommand.isUndo(t), "\(t)") }
    for t in ["Scratch that idea and start over.", "I said scratch that", "Scratch the last part."] { #expect(!VoiceCommand.isUndo(t), "\(t)") }
}


@Test func aDoubtedCutOffWordIsDroppedAndNothingElse() {
    let words = BundledWordList.shared
    let known: (String) -> Bool = { words.contains($0) }
    let starts: (String) -> Bool = { words.startsAWord($0) }
    // Cut off as the speaker changed course: doubted, unknown, and the start of a real word.
    #expect(Doubt.cutOffs(["tra"], in: "I was tra trying to finish it", isKnown: known, startsAWord: starts) == ["tra"])
    #expect(Doubt.removing(["tra"], from: "I was tra trying to finish it") == "I was trying to finish it")
    #expect(Doubt.removing(["bu"], from: "It's fine, bu, honestly.") == "It's fine, honestly.")
    // Kept: a real word, a name (capital), a made-up word that starts nothing, a sound said again, a long word.
    #expect(Doubt.cutOffs(["read"], in: "I read it", isKnown: known, startsAWord: starts).isEmpty)
    #expect(Doubt.cutOffs(["Zorvex"], in: "Ask Zorvex", isKnown: known, startsAWord: starts).isEmpty)
    #expect(Doubt.cutOffs(["zzq"], in: "the zzq part", isKnown: known, startsAWord: starts).isEmpty)
    #expect(Doubt.cutOffs(["dum"], in: "dum dum dum", isKnown: known, startsAWord: starts).isEmpty)
    #expect(Doubt.cutOffs(["frobnicat"], in: "we frobnicat it", isKnown: known, startsAWord: starts).isEmpty)
    #expect(words.startsAWord("tra") && !words.startsAWord("zzq"))
}
