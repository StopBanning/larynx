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

    public static func paste(_ text: String, restoreAfter delay: TimeInterval = 0.5) throws {
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
