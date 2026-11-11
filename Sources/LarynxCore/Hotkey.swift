import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Hold-to-talk on a single modifier key, watched with a keyboard event tap.
/// macOS switches taps off if a callback is slow; we turn ours straight back on.
public final class Hotkey: @unchecked Sendable {
    public enum Key: String, CaseIterable, Sendable {
        case fn, rightOption, rightCommand, rightControl

        var keyCode: Int64 {
            switch self {
            case .fn: return Int64(kVK_Function)
            case .rightOption: return Int64(kVK_RightOption)
            case .rightCommand: return Int64(kVK_RightCommand)
            case .rightControl: return Int64(kVK_RightControl)
            }
        }

        var flag: CGEventFlags {
            switch self {
            case .fn: return .maskSecondaryFn
            case .rightOption: return .maskAlternate
            case .rightCommand: return .maskCommand
            case .rightControl: return .maskControl
            }
        }
    }

    /// Can change while running (the menu bar app's Talk Key menu).
    public var keys: [Key]
    /// Hands-free: a quick double-tap of a talk key keeps recording after you let go; the next press finishes.
    public var doubleTapLocks = true
    /// Keys that toggle hands-free with a single press (a second macro-pad button, say): press to start, press to finish.
    public var toggleKeys: [Key] = []
    private let onDown: () -> Void
    private let onUp: () -> Void
    private let onCancel: () -> Void
    private let onLock: () -> Void
    private var tap: CFMachPort?
    private var isDown = false
    private var cancelled = false
    /// Recording continues with no key held (hands-free).
    public private(set) var isLocked = false
    private var downAt = Date.distantPast
    private var lastTapUp = Date.distantPast
    private var secondTap = false
    /// The press that finished hands-free (or started it with a toggle key): its release does nothing.
    private var swallowUp = false
    /// A press shorter than this counts as a tap.
    static let tapSeconds: TimeInterval = 0.35
    /// The second tap must start within this long after the first one ended.
    static let doubleTapGap: TimeInterval = 0.4

    public convenience init(key: Key, onDown: @escaping () -> Void, onUp: @escaping () -> Void) {
        self.init(keys: [key], onDown: onDown, onUp: onUp, onCancel: {})
    }

    /// Any one of `keys` works as the talk key.
    /// `onCancel` fires instead of `onUp` when another key is pressed while the talk key is held (a shortcut, not dictation).
    public init(keys: [Key], onDown: @escaping () -> Void, onUp: @escaping () -> Void, onCancel: @escaping () -> Void,
                onLock: @escaping () -> Void = {}) {
        self.keys = keys
        self.onCancel = onCancel
        self.onDown = onDown
        self.onUp = onUp
        self.onLock = onLock
    }

    /// Finishes hands-free without a key press (the time limit), exactly as a press would.
    public func finishLocked() { guard isLocked else { return }; isLocked = false; onUp() }

    /// True once the user has allowed this app under Privacy & Security > Input Monitoring.
    public static var canListen: Bool { CGPreflightListenEventAccess() }

    /// Shows macOS's Input Monitoring prompt (once) and lists the app in Settings.
    public static func requestListen() { _ = CGRequestListenEventAccess() }

    /// Needs Input Monitoring permission. Returns false if macOS refused the tap.
    @discardableResult
    public func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                Unmanaged<Hotkey>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            }, userInfo: me)
        else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        if type == .keyDown {
            otherKeyDown(code: event.getIntegerValueField(.keyboardEventKeycode))
            return
        }
        guard type == .flagsChanged else { return }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if ProcessInfo.processInfo.environment["LARYNX_DEBUG"] != nil {
            FileHandle.standardError.write(Data("larynx key: code \(code) flags \(event.flags.rawValue)\n".utf8))
        }
        guard let key = (keys + toggleKeys).first(where: { $0.keyCode == code }) else { return }
        keyChanged(key, pressed: event.flags.contains(key.flag))
    }

    /// A non-modifier key went down.
    func otherKeyDown(code: Int64) {
        if isLocked {
            // Hands-free: typing elsewhere is fine; Esc throws the recording away.
            if code == Int64(kVK_Escape) { isLocked = false; onCancel() }
            return
        }
        if isDown { isDown = false; cancelled = true; onCancel() }  // a shortcut, not dictation
    }

    /// A talk or toggle key went down or up. The whole hold / tap / double-tap / hands-free state machine.
    func keyChanged(_ key: Key, pressed: Bool, now: Date = Date()) {
        let isToggle = toggleKeys.contains(key) && !keys.contains(key)
        if pressed {
            guard !isDown, !swallowUp else { return }
            if isLocked { isLocked = false; swallowUp = true; onUp(); return }  // any talk key finishes hands-free
            if isToggle { swallowUp = true; onDown(); isLocked = true; onLock(); return }
            guard !cancelled else { return }
            isDown = true
            downAt = now
            secondTap = doubleTapLocks && now.timeIntervalSince(lastTapUp) < Hotkey.doubleTapGap
            onDown()
        } else {
            if swallowUp { swallowUp = false; return }
            defer { cancelled = false }
            guard isDown else { return }
            isDown = false
            let held = now.timeIntervalSince(downAt)
            if secondTap, held < Hotkey.tapSeconds {
                lastTapUp = .distantPast
                isLocked = true
                onLock()
                return
            }
            lastTapUp = held < Hotkey.tapSeconds ? now : .distantPast
            onUp()
        }
    }
}
