import AppKit
import LarynxCore

/// Main-run-loop capture state. Finished utterances keep their own target and lifecycle during async work.
@MainActor final class ListenSession {
    static var current: ListenSession?
    // Preserve the single outstanding preview request shared across successive recordings.
    static var previewBusy = false
    /// The preview waits until then: it backs off on a slow Mac (see the preview timer in Listen.swift).
    static var nextPreview = Date.distantPast
    let target: NSRunningApplication?
    /// When the talk key went down: a long hold with almost no audio means the microphone, not a tap.
    let pressedAt = Date()
    var state = SessionState()
    var previewTimer: Timer?
    /// A password field or an app on the privacy list: the words never touch the disk.
    var privateField = false
    /// Names and terms on screen for this dictation, if they were gathered in time (shadow for now).
    var contextTerms: [String]?
    /// Hands-free: recording with no key held.
    var locked = false
    /// Where this dictation's time goes, filled in as it happens; saved with it in history.
    var timing = History.Timing()
    /// Casual or professional, fixed when the key goes down.
    var style: Style = .casual
    /// When the previous dictation finished delivering, for the idle gap before the next one.
    static var lastDelivered: Date?

    init(target: NSRunningApplication?) {
        self.target = target
        state.start()
    }

    func stopPreview() { previewTimer?.invalidate(); previewTimer = nil }
    func reset() { stopPreview(); state.reset(); if Self.current === self { Self.current = nil } }
    var shouldPresent: Bool { Self.current === self }
    var isCurrentRecording: Bool { Self.current === self && state.phase == .recording }
}
