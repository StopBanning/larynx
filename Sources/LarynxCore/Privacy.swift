import AppKit
import ApplicationServices

/// Where Larynx must not keep anything: password fields and apps that hold secrets.
public enum Privacy {
    /// Password managers and keychains. Add more in `~/Library/Application Support/Larynx/privacy.json`
    /// (a JSON array of bundle ids).
    public static let builtInApps: Set<String> = [
        "com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "com.dashlane.dashlanephonefinal", "com.lastpass.LastPass", "in.sinew.Enpass-Desktop",
        "org.keepassxc.keepassxc", "com.proton.pass.electron",
    ]

    public static var fileURL: URL { History.shared.root.appendingPathComponent("privacy.json") }

    public static func excludedApps() -> Set<String> {
        let extra = (try? Data(contentsOf: fileURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
        return builtInApps.union(extra)
    }

    /// True when the words being dictated must stay in memory only: Secure Input is on (a password field has focus
    /// somewhere), the focused element is a secure text field, or the app is on the privacy list.
    public static func isPrivate(app: NSRunningApplication?) -> Bool {
        if Inserter.secureInputActive { return true }
        guard let app else { return false }
        if let id = app.bundleIdentifier, excludedApps().contains(id) { return true }
        guard Inserter.isTrusted else { return false }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // Runs at key-down: a hung app must not stall the talk key (the default timeout is 6 s).
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        let element = value as! AXUIElement
        for attribute in [kAXRoleAttribute, kAXSubroleAttribute] {
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &v) == .success, (v as? String) == "AXSecureTextField" { return true }
        }
        return false
    }
}

public extension Inserter {
    /// Where the focused text field is on screen, in Cocoa coordinates (origin bottom-left of the main display), or
    /// nil when the app doesn't say. Lets the pill sit just above the field instead of covering it.
    static func focusedFieldFrame(in app: NSRunningApplication?) -> NSRect? {
        guard isTrusted, let app else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent),
              extent.width > 20, extent.height > 8 else { return nil }
        // Accessibility uses a top-left origin on the main display; AppKit uses bottom-left.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: point.x, y: mainHeight - point.y - extent.height, width: extent.width, height: extent.height)
    }
}
