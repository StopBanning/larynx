import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Puts text into whatever app has focus: clipboard plus a synthetic Cmd+V, then the old clipboard comes back.
public enum Inserter {
    /// True once the user has allowed this app in System Settings > Privacy & Security > Accessibility.
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own Accessibility prompt. The user flips the switch; we never do.
    public static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Password fields turn on Secure Input, which blocks synthetic keystrokes.
    public static var secureInputActive: Bool { IsSecureEventInputEnabled() }

    public static func paste(_ text: String, restoreAfter delay: TimeInterval = 0.5, restore: Bool = true) throws {
        guard !text.isEmpty else { return }
        guard isTrusted else { throw LarynxError.notTrusted }
        guard !secureInputActive else { throw LarynxError.secureInput }

        let board = NSPasteboard.general
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        board.clearContents()
        board.setString(text, forType: .string)
        let ourChange = board.changeCount

        sendCommandV()
        guard restore else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // Leave the clipboard alone if the user copied something new meanwhile.
            guard board.changeCount == ourChange else { return }
            board.clearContents()
            let items = saved.map { pairs -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in pairs { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { board.writeObjects(items) }
        }
    }

    /// Puts text on the clipboard and leaves it there, for when pasting is impossible. The transcript is never lost.
    public static func copyOnly(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    public enum Delivery: Sendable, Equatable {
        case inserted
        case copied(String)  // why the paste didn't happen
        case pastedAndCopied(String)  // pasted, but it's unclear a text field took it, so it's also on the clipboard

        public var label: String {
            switch self {
            case .inserted: return "inserted"
            case .copied: return "copied"
            case .pastedAndCopied: return "pasted+copied"
            }
        }
    }

    /// Pastes into `target` (the app that was in front when the user started talking), bringing it back to the front
    /// first if they switched away. Anything that stops the paste falls back to leaving the text on the clipboard.
    /// `LARYNX_FORCE_COPY=1` forces the fallback, for testing.
    @MainActor
    public static func deliver(_ text: String, to target: NSRunningApplication? = nil) async -> Delivery {
        if ProcessInfo.processInfo.environment["LARYNX_FORCE_COPY"] == "1" {
            copyOnly(text); return .copied("LARYNX_FORCE_COPY is set")
        }
        if let target, NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            guard !target.isTerminated else { copyOnly(text); return .copied("the app you started in has quit") }
            target.activate()
            for _ in 0..<6 where NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
                copyOnly(text); return .copied("could not bring \(target.localizedName ?? "the app") back to the front")
            }
            try? await Task.sleep(nanoseconds: 80_000_000)  // let its window take key focus
        }
        let focus = focusedField(in: target ?? NSWorkspace.shared.frontmostApplication)
        guard focus.editable != false else {
            // Nothing to type into: pressing ⌘V would lose the words, so leave them on the clipboard.
            copyOnly(text); return .copied("no text field has focus (\(focus.role))")
        }
        do {
            // When macOS can't say whether a text field has focus, paste anyway but keep the words on the clipboard.
            try paste(text, restore: focus.editable == true)
            return focus.editable == true ? .inserted : .pastedAndCopied(focus.role)
        }
        catch { copyOnly(text); return .copied("\(error)") }
    }

    /// What has keyboard focus in `app`: `editable` is true for a text field, false for something that can't take
    /// text (a button, a list, the window itself, nothing at all), nil when the app doesn't say.
    public static func focusedField(in app: NSRunningApplication?) -> (editable: Bool?, role: String) {
        guard isTrusted, let app else { return (nil, "unknown") }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // Chrome and Electron apps (Claude, Slack, VS Code) only build their accessibility tree when asked.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &value)
        if err == .noValue {
            // Chrome can report no focused element even with a page open; only trust "nothing" when there's no window either.
            var window: CFTypeRef?
            let hasWindow = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &window) == .success
            return hasWindow ? (nil, "window without a focused element") : (false, "no window")
        }
        guard err == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (nil, "unknown (\(err.rawValue))") }
        let element = value as! AXUIElement
        func string(_ attr: String) -> String? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, attr as CFString, &v) == .success ? v as? String : nil
        }
        let role = string(kAXRoleAttribute) ?? "?"
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) { return (true, role) }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success, settable.boolValue {
            return (true, role)
        }
        var editable: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editable) == .success, (editable as? Bool) == true {
            return (true, role)
        }
        // Terminals and some custom editors take typing without looking like text fields.
        if ["AXScrollArea", "AXGroup", "AXUnknown", "AXWebArea"].contains(role) { return (nil, role) }
        return (false, role)
    }

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(keyCodeForV())
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// The key that types "v" in the current layout (Dvorak, AZERTY...), falling back to the US position.
    private static func keyCodeForV() -> Int {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return kVK_ANSI_V }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> Int in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return kVK_ANSI_V }
            for code in 0..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
                if status == noErr, length == 1, chars[0] == UniChar(UInt8(ascii: "v")) { return code }
            }
            return kVK_ANSI_V
        }
    }
}
