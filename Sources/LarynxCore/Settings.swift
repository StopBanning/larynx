import Foundation
import CoreFoundation

/// Settings are read on access, so atomic file replacements take effect on the next request/menu open.
/// Command-line overrides belong to the caller; precedence here is JSON > legacy defaults > built-in default.
public final class Settings: @unchecked Sendable {
    public static let shared = Settings()
    /// `LARYNX_DATA_DIR` moves settings.json along with history (tests use a throwaway folder).
    public static let defaultURL = (ProcessInfo.processInfo.environment["LARYNX_DATA_DIR"]
        .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Larynx"))
        .appendingPathComponent("settings.json")

    public enum Key: String, CaseIterable, Sendable {
        case engine, rewrite, vocabulary, vocabularyRoots, devTerms, preview, learn, keys, loginItemSet
        case history, historyDays, keepAudio, debugText, pillPosition, pillGlass, handsFree, toggleKeys, doubtHint, micWarm, verifyPaste, fitToField, context, onboarded, micDevice
        case style, professionalKey, professionalSwearing
        case snippetStage = "stages.snippet"
        case dictionaryStage = "stages.dictionary"
        case vocabularyCaseStage = "stages.vocabularyCase"
        case tidyStage = "stages.tidy"
        case numbersStage = "stages.numbers"
        case rewriteStage = "stages.rewrite"

        public var defaultValue: String {
            switch self {
            case .engine: return "ultra"
            case .rewrite: return "auto"
            case .vocabularyRoots: return "~/work"
            case .keys, .toggleKeys, .micDevice: return ""
            case .loginItemSet: return "false"
            case .historyDays: return "30"
            case .keepAudio, .debugText: return "off"
            case .pillPosition: return "auto"
            case .pillGlass: return "25"
            case .micWarm: return "30"
            case .context: return "app-only"  // the window walk is opt-in: suspected in two Claude freezes (Nov 11)
            case .onboarded: return "false"
            case .style: return "casual"
            case .professionalKey: return "none"
            case .professionalSwearing: return "remove"
            default: return "on"
            }
        }

        fileprivate func valid(_ value: String) -> Bool {
            switch self {
            case .engine: return ["clean", "parakeet", "bark3", "ultra", "unified"].contains(value)
            case .rewrite: return ["auto", "off"].contains(value)
            case .vocabulary, .devTerms, .preview, .learn, .history, .debugText, .handsFree, .doubtHint, .verifyPaste, .fitToField: return ["on", "off"].contains(value)
            case .pillPosition: return ["auto", "bottom"].contains(value)
            case .pillGlass: return Int(value).map { (0...100).contains($0) } ?? false
            case .micWarm: return Int(value).map { (0...300).contains($0) } ?? false
            case .context: return ["on", "app-only", "off"].contains(value)
            case .historyDays: return Int(value).map { (1...3650).contains($0) } ?? false
            case .keepAudio: return value == "off" || (Int(value).map { (1...365).contains($0) } ?? false)
            case .loginItemSet, .onboarded: return ["true", "false"].contains(value)
            case .style: return ["casual", "professional"].contains(value)
            case .professionalKey: return value == "none" || Hotkey.Key(rawValue: value) != nil
            case .professionalSwearing: return ["remove", "keep"].contains(value)
            case .keys, .vocabularyRoots, .toggleKeys, .micDevice: return true
            default: return StageMode(rawValue: value) != nil
            }
        }
    }

    public struct Snapshot: Sendable {
        private let values: [Key: String]
        public init(values: [Key: String] = [:]) {
            self.values = values.filter { $0.key.valid($0.value) }
        }
        public func string(_ key: Key) -> String { values[key] ?? key.defaultValue }
        public func bool(_ key: Key) -> Bool { string(key) == "true" }
        public func stageMode(_ key: Key) -> StageMode { StageMode(rawValue: string(key)) ?? .on }
        /// A whole number of days, or nil for "off".
        public func days(_ key: Key) -> Int? { Int(string(key)) }
    }

    public enum WriteError: Error { case invalidFile, invalidValue }
    public let url: URL
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cachedData: Data?
    private var fileValues: [String: Any] = [:]

    public init(url: URL = Settings.defaultURL, defaults: UserDefaults = .standard) {
        self.url = url
        self.defaults = defaults
    }

    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let data = try? Data(contentsOf: url)
        if data != cachedData {
            cachedData = data
            if let data {
                // Keep the last valid configuration during a partial/malformed edit.
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { fileValues = object }
            } else { fileValues = [:] }
        }
        var values: [Key: String] = [:]
        for key in Key.allCases {
            let pieces = key.rawValue.split(separator: ".").map(String.init)
            let value: Any? = pieces.count == 2
                ? (fileValues[pieces[0]] as? [String: Any])?[pieces[1]] : fileValues[key.rawValue]
            var fromFile = value as? String
            if key == .loginItemSet, let value, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
                fromFile = (value as? Bool).map(String.init)
            } else if fromFile == nil, let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                fromFile = String(number.intValue)  // "historyDays": 30 as a JSON number
            }
            let legacy = key == .loginItemSet ? String(defaults.bool(forKey: key.rawValue)) : defaults.string(forKey: key.rawValue)
            if let fromFile, key.valid(fromFile) { values[key] = fromFile }
            else if let legacy, key.valid(legacy) { values[key] = legacy }
        }
        return Snapshot(values: values)
    }

    public func string(_ key: Key) -> String { snapshot().string(key) }
    public func bool(_ key: Key) -> Bool { snapshot().bool(key) }

    /// Menu writes preserve unknown JSON fields and mirror the value to the legacy defaults store.
    public func set(_ value: String, for key: Key) throws {
        guard key.valid(value) else { throw WriteError.invalidValue }
        lock.lock(); defer { lock.unlock() }
        var object: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WriteError.invalidFile }
            object = decoded
        }
        let stored: Any = key == .loginItemSet ? (value == "true") : value as Any
        let pieces = key.rawValue.split(separator: ".").map(String.init)
        if pieces.count == 2 {
            var stages = object[pieces[0]] as? [String: Any] ?? [:]
            stages[pieces[1]] = stored
            object[pieces[0]] = stages
        } else { object[key.rawValue] = stored }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        defaults.set(stored, forKey: key.rawValue)
        cachedData = data
        fileValues = object
    }
}

public enum StageMode: String, Codable, Sendable { case off, shadow, on }
