import Testing
@testable import LarynxText

private struct Words: WordList {
    let set: Set<String>
    init(_ words: String) { set = Set(words.split(separator: " ").map { $0.lowercased() }) }
    func contains(_ word: String) -> Bool { set.contains(word.lowercased()) }
}

/// Real words for these tests; anything else counts as invented by the speech model.
private let english = Words("""
    how are things going tell to start the meeting on tuesday wednesday i send sent it now testing one two three \
    touching cool beings beans we looking alright use go here locust rust russ please report tomorrow ship today \
    with team a can you check update cash cache is full let's do that at noon
    """)

private func learn(_ a: String, _ b: String) -> [Corrections.Lesson] {
    Corrections.lessons(Corrections.changes(previous: a, current: b), words: english)
}

@Test func inventedWordsBecomeDictionaryEntries() {
    #expect(learn("How are things Golang?", "How are things going?") == [.dictionary(heard: "Golang", meant: "going")])
    #expect(learn("Tell Logus to start the meeting.", "Tell Locust to start the meeting.")
            == [.dictionary(heard: "Logus", meant: "Locust")])
    #expect(learn("Can you check the Gavy app now", "Can you check the Govee app now")
            == [.dictionary(heard: "Gavy", meant: "Govee"), .vocabulary("Govee")])
    #expect(learn("we use go lang here", "we use Golang here")
            == [.dictionary(heard: "go lang", meant: "Golang"), .vocabulary("Golang")])
}

@Test func realWordChangesAreOnlySuggestions() {
    #expect(learn("Russ is the update", "Rust is the update") == [.suggestion(heard: "Russ", meant: "Rust")])
    #expect(learn("The cash is full now", "The cache is full now") == [.suggestion(heard: "cash", meant: "cache")])
    #expect(learn("Alright cool beings. How are we looking?", "Cool beans. How are we looking?")
            == [.suggestion(heard: "beings", meant: "beans")])
}

@Test func changedMindsAndDifferentSentencesTeachNothing() {
    #expect(learn("Ship the meeting on Tuesday", "Ship the meeting on Wednesday").isEmpty)  // not alike
    #expect(learn("I send it now", "I sent it now") == [.suggestion(heard: "send", meant: "sent")])
    #expect(learn("Please send the report tomorrow", "Let's do that at noon").isEmpty)
    #expect(learn("Testing one two three", "Testing one two three").isEmpty)  // identical
    #expect(learn("ok go", "ok going").isEmpty)  // too short to be sure
    #expect(learn("Tell Logus to start", "tell logus to start").isEmpty)  // case only
    #expect(learn("Please send the report tomorrow", "Please send the report tomorrow with the team").isEmpty)  // added words
    #expect(Corrections.changes(previous: "one two three four five", current: "one six seven eight five").isEmpty)  // too different
}
