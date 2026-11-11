import Foundation
import Testing
@testable import LarynxCore

/// Records what the key listener asked for, driven by synthetic key changes and timestamps.
private final class Probe {
    var events: [String] = []
    lazy var hotkey = Hotkey(keys: [.rightCommand], onDown: { self.events.append("down") }, onUp: { self.events.append("up") },
                             onCancel: { self.events.append("cancel") }, onLock: { self.events.append("lock") })
    var t = Date(timeIntervalSince1970: 1_000)
    func press(_ key: Hotkey.Key = .rightCommand, after: TimeInterval = 0.05) { t += after; hotkey.keyChanged(key, pressed: true, now: t) }
    func release(_ key: Hotkey.Key = .rightCommand, after: TimeInterval) { t += after; hotkey.keyChanged(key, pressed: false, now: t) }
}

@Test func holdToTalkIsUnchanged() {
    let p = Probe()
    p.press(); p.release(after: 2.0)
    #expect(p.events == ["down", "up"])
    #expect(!p.hotkey.isLocked)
}

@Test func doubleTapLocksAndTheNextPressFinishes() {
    let p = Probe()
    p.press(); p.release(after: 0.12)            // first tap: a too-short recording the app discards
    p.press(after: 0.15); p.release(after: 0.12) // second tap: stays recording
    #expect(p.events == ["down", "up", "down", "lock"])
    #expect(p.hotkey.isLocked)
    p.hotkey.otherKeyDown(code: 0)               // typing elsewhere doesn't stop hands-free
    #expect(p.hotkey.isLocked)
    p.press(after: 20); p.release(after: 0.1)    // one press finishes; its release is ignored
    #expect(p.events == ["down", "up", "down", "lock", "up"])
    #expect(!p.hotkey.isLocked)
}

@Test func slowSecondTapOrLongSecondPressDoesNotLock() {
    let p = Probe()
    p.press(); p.release(after: 0.12)
    p.press(after: 0.9); p.release(after: 0.12)  // too long a gap: two separate taps
    #expect(!p.hotkey.isLocked)
    let q = Probe()
    q.press(); q.release(after: 0.12)
    q.press(after: 0.15); q.release(after: 3.0)  // tap then a real hold: normal dictation
    #expect(q.events == ["down", "up", "down", "up"])
    #expect(!q.hotkey.isLocked)
}

@Test func escapeCancelsHandsFreeAndShortcutsCancelAHold() {
    let p = Probe()
    p.press(); p.release(after: 0.1); p.press(after: 0.1); p.release(after: 0.1)
    p.hotkey.otherKeyDown(code: 53)  // Esc
    #expect(p.events.last == "cancel")
    #expect(!p.hotkey.isLocked)
    let q = Probe()
    q.press(); q.hotkey.otherKeyDown(code: 8)  // ⌘C while holding: a shortcut
    q.release(after: 0.3)
    #expect(q.events == ["down", "cancel"])
}

@Test func toggleKeyStartsAndFinishesWithOnePressEach() {
    let p = Probe()
    p.hotkey.toggleKeys = [.rightControl]
    p.press(.rightControl); p.release(.rightControl, after: 0.1)
    #expect(p.events == ["down", "lock"])
    p.press(.rightControl, after: 10); p.release(.rightControl, after: 0.1)
    #expect(p.events == ["down", "lock", "up"])
    p.hotkey.doubleTapLocks = false
    let q = Probe(); q.hotkey.doubleTapLocks = false
    q.press(); q.release(after: 0.1); q.press(after: 0.1); q.release(after: 0.1)
    #expect(!q.hotkey.isLocked)  // double-tap turned off
}
