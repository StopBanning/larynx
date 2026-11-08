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

    private let keys: [Key]
    private let onDown: () -> Void
    private let onUp: () -> Void
    private var tap: CFMachPort?
    private var isDown = false

    public convenience init(key: Key, onDown: @escaping () -> Void, onUp: @escaping () -> Void) {
        self.init(keys: [key], onDown: onDown, onUp: onUp)
    }

    /// Any one of `keys` works as the talk key.
    public init(keys: [Key], onDown: @escaping () -> Void, onUp: @escaping () -> Void) {
        self.keys = keys
        self.onDown = onDown
        self.onUp = onUp
    }

    /// True once the user has allowed this app under Privacy & Security > Input Monitoring.
    public static var canListen: Bool { CGPreflightListenEventAccess() }

    /// Shows macOS's Input Monitoring prompt (once) and lists the app in Settings.
    public static func requestListen() { _ = CGRequestListenEventAccess() }

    /// Needs Input Monitoring permission. Returns false if macOS refused the tap.
    @discardableResult
    public func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
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
        guard type == .flagsChanged else { return }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if ProcessInfo.processInfo.environment["LARYNX_DEBUG"] != nil {
            FileHandle.standardError.write(Data("larynx key: code \(code) flags \(event.flags.rawValue)\n".utf8))
        }
        guard let key = keys.first(where: { $0.keyCode == code }) else { return }
        let pressed = event.flags.contains(key.flag)
        if pressed, !isDown { isDown = true; onDown() }
        else if !pressed, isDown { isDown = false; onUp() }
    }
}
