import Foundation
import LarynxText

/// One pipeline decision. Shadow decisions retain the original text and set applied to false.
public struct Step: Codable, Equatable, Sendable {
    public var stage: String
    public var before: String
    public var after: String
    public var applied: Bool

    public init(stage: String, before: String, after: String, applied: Bool) {
        self.stage = stage
        self.before = before
        self.after = after
        self.applied = applied
    }
}

/// A finished dictation. Coding keys preserve the original serve wire format.
public struct Transcript: Codable, Equatable, Sendable {
    public var text: String
    public var raw: String
    public var engine: String
    public var mode: CleanupMode
    public var audioSeconds: Double
    public var asrMs: Int
    public var rewriteMs: Int
    public var totalMs: Int
    public var rewrite: String
    public var rewritten: Bool
    /// The speech model's own confidence for the whole clip (0-1).
    public var confidence: Double?
    /// Words the model probably misheard (very low confidence, or unknown to the dictionary), still in the text.
    public var doubtful: [String]?
    public var steps: [Step]
    public var snippet: String?
    public var delivered: String?
    public var pasted: Bool?
    public var pasteError: String?

    public init(text: String, raw: String, engine: String, mode: CleanupMode, audioSeconds: Double,
                asrMs: Int, rewriteMs: Int, totalMs: Int, rewrite: String, rewritten: Bool,
                confidence: Double? = nil, doubtful: [String]? = nil, steps: [Step] = [], snippet: String? = nil,
                delivered: String? = nil, pasted: Bool? = nil, pasteError: String? = nil) {
        self.text = text
        self.raw = raw
        self.engine = engine
        self.mode = mode
        self.audioSeconds = audioSeconds
        self.asrMs = asrMs
        self.rewriteMs = rewriteMs
        self.totalMs = totalMs
        self.rewrite = rewrite
        self.rewritten = rewritten
        self.confidence = confidence
        self.doubtful = doubtful
        self.steps = steps
        self.snippet = snippet
        self.delivered = delivered
        self.pasted = pasted
        self.pasteError = pasteError
    }

    private enum CodingKeys: String, CodingKey {
        case text, raw, engine, mode, audioSeconds, asrMs, rewriteMs, totalMs, rewrite, rewritten
        case confidence, doubtful, steps, snippet, delivered, pasted, pasteError
    }

    /// Also accepts the original serve result records, which predate steps and confidence.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(text: try c.decode(String.self, forKey: .text),
                  raw: try c.decode(String.self, forKey: .raw),
                  engine: try c.decode(String.self, forKey: .engine),
                  mode: try c.decode(CleanupMode.self, forKey: .mode),
                  audioSeconds: try c.decode(Double.self, forKey: .audioSeconds),
                  asrMs: try c.decode(Int.self, forKey: .asrMs),
                  rewriteMs: try c.decode(Int.self, forKey: .rewriteMs),
                  totalMs: try c.decode(Int.self, forKey: .totalMs),
                  rewrite: try c.decode(String.self, forKey: .rewrite),
                  rewritten: try c.decode(Bool.self, forKey: .rewritten),
                  confidence: try c.decodeIfPresent(Double.self, forKey: .confidence),
                  doubtful: try c.decodeIfPresent([String].self, forKey: .doubtful),
                  steps: try c.decodeIfPresent([Step].self, forKey: .steps) ?? [],
                  snippet: try c.decodeIfPresent(String.self, forKey: .snippet),
                  delivered: try c.decodeIfPresent(String.self, forKey: .delivered),
                  pasted: try c.decodeIfPresent(Bool.self, forKey: .pasted),
                  pasteError: try c.decodeIfPresent(String.self, forKey: .pasteError))
    }

    /// The only untyped boundary: attach a serve request ID/event or an MCP envelope to encoded fields.
    public func jsonObject() throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try JSONSerialization.jsonObject(with: encoder.encode(self)) as! [String: Any]
    }
}
