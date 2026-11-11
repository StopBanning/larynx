import Foundation
import Testing
import LarynxCore

private final class SettingsFixture {
    let folder: URL
    let defaults: UserDefaults
    let suite: String
    let settings: Settings
    init() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("larynx-settings-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suite = "larynx-settings-tests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        settings = Settings(url: folder.appendingPathComponent("settings.json"), defaults: defaults)
    }
    deinit {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }
    func write(_ text: String) throws { try Data(text.utf8).write(to: settings.url, options: .atomic) }
}

@Test func settingsReloadJSONAndPreserveLegacyFallbacks() throws {
    let f = try SettingsFixture()
    #expect(f.settings.string(.engine) == "clean")
    f.defaults.set("parakeet", forKey: "engine")
    #expect(f.settings.string(.engine) == "parakeet")
    try f.write(#"{"engine":"clean","stages":{"tidy":"shadow"},"loginItemSet":true}"#)
    #expect(f.settings.string(.engine) == "clean")
    #expect(f.settings.snapshot().stageMode(.tidyStage) == .shadow)
    #expect(f.settings.bool(.loginItemSet))
    let previous = f.settings.snapshot()
    try f.write(#"{"engine":"parakeet","stages":{"tidy":"off"}}"#)
    #expect(f.settings.string(.engine) == "parakeet")
    #expect(f.settings.snapshot().stageMode(.tidyStage) == .off)
    #expect(previous.string(.engine) == "clean")
    try f.write("{")
    #expect(f.settings.snapshot().stageMode(.tidyStage) == .off)
    try f.write(#"{"engine":123,"stages":{"tidy":"invalid"}}"#)
    #expect(f.settings.string(.engine) == "parakeet")
    #expect(f.settings.snapshot().stageMode(.tidyStage) == .on)
    try FileManager.default.removeItem(at: f.settings.url)
    #expect(f.settings.string(.engine) == "parakeet")
    #expect(f.settings.snapshot().stageMode(.tidyStage) == .on)
}

@Test func settingsWritesAreAtomicAndRetainUnknownFields() throws {
    let f = try SettingsFixture()
    try f.write(#"{"future":{"keep":42},"stages":{"futureStage":"shadow"},"preview":"off"}"#)
    try f.settings.set("on", for: .preview)
    try f.settings.set("shadow", for: .dictionaryStage)
    #expect(f.settings.string(.preview) == "on")
    #expect(f.defaults.string(forKey: "preview") == "on")
    let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.settings.url)) as? [String: Any])
    #expect((object["future"] as? [String: Int])?["keep"] == 42)
    #expect((object["stages"] as? [String: String])?["futureStage"] == "shadow")
    #expect((object["stages"] as? [String: String])?["dictionary"] == "shadow")
    try f.write("[")
    #expect(throws: (any Error).self) { try f.settings.set("off", for: .preview) }
    #expect(try String(contentsOf: f.settings.url, encoding: .utf8) == "[")
    #expect(throws: Settings.WriteError.self) { try f.settings.set("yes", for: .preview) }
}

@Test func everySettingIsDocumented() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let doc = try String(contentsOf: root.appendingPathComponent("docs/SETTINGS.md"), encoding: .utf8)
    for key in Settings.Key.allCases {
        let value = key.defaultValue.isEmpty ? "\"\"" : key.defaultValue
        #expect(doc.contains("| `\(key.rawValue)` | `\(value)` |"), "undocumented key/default: \(key.rawValue)")
    }
}
