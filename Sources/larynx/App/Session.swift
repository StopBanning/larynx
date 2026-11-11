import AppKit
import LarynxCore

/// Main-run-loop capture state. Finished utterances keep their own target and lifecycle during async work.
@MainActor final class ListenSession {
    static var current: ListenSession?
    // Preserve the single outstanding preview request shared across successive recordings.
    static var previewBusy = false
    let target: NSRunningApplication?
    var state = SessionState()
    var previewTimer: Timer?
    /// A password field or an app on the privacy list: the words never touch the disk.
    var privateField = false
    /// Hands-free: recording with no key held.
    var locked = false

    init(target: NSRunningApplication?) {
        self.target = target
        state.start()
    }

    func stopPreview() { previewTimer?.invalidate(); previewTimer = nil }
    func reset() { stopPreview(); state.reset(); if Self.current === self { Self.current = nil } }
    var shouldPresent: Bool { Self.current === self }
    var isCurrentRecording: Bool { Self.current === self && state.phase == .recording }
}
