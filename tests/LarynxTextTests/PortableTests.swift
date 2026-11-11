import Testing
import LarynxText

@Test func bundledEnglishSpelling() {
    let list = BundledWordList.shared
    #expect(list.count == 56372)
    for word in ["going", "chat", "jobs", "coding", "umbrella", "humble", "can't"] {
        #expect(list.contains(word), "\(word)")
        #expect(list.contains(word.uppercased()), "\(word)")
    }
    for word in ["", "qzxvzz", "two words", " going", "going "] {
        #expect(!list.contains(word), "\(word)")
    }
}

@Test func portableDictionaryPreservesBoundariesAndLiteralText() {
    let map = ["lynx": "Larynx", "lynx app": "Larynx app", "dollar": "$5\\tip"]
    #expect(Dictionary.apply("LYNX app and lynxes cost a dollar.", map: map) == "Larynx app and lynxes cost a $5\\tip.")
    #expect(Dictionary.apply("Keep going.", map: map) == "Keep going.")
}

@Test func portableSnippetsRequireWholeUtterance() {
    let map = ["my link": "https://example.com"]
    #expect(Snippets.match("Insert my link!", in: map)?.text == "https://example.com")
    #expect(Snippets.match("Please include my link in the reply.", in: map) == nil)
}
