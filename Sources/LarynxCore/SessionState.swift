import Foundation

/// A single utterance's lifecycle. A new recording owns a new state machine even while an older one finishes.
public struct SessionState: Equatable, Sendable {
    public enum Phase: String, Sendable { case idle, recording, finishing, delivering }
    public private(set) var phase: Phase = .idle
    public init() {}

    @discardableResult public mutating func start() -> Bool {
        guard phase == .idle else { return false }
        phase = .recording
        return true
    }
    @discardableResult public mutating func finish() -> Bool {
        guard phase == .recording else { return false }
        phase = .finishing
        return true
    }
    @discardableResult public mutating func deliver() -> Bool {
        guard phase == .finishing else { return false }
        phase = .delivering
        return true
    }
    public mutating func reset() { phase = .idle }
}
