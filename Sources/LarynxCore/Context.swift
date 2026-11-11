import AppKit
import ApplicationServices

/// What's around the cursor and on screen when a dictation starts (PLAN-v1 C1, master 2.1), used to spell names the
/// speech model has never heard ("Claude", "Dock") the way they appear on screen. Gathered at key-down on a
/// background thread within a time budget; late context is dropped, never waited for. Lives in memory for one
/// dictation; never logged or stored. Nothing is read from password fields or private apps.
public struct ScreenContext: Sendable {
    public var windowTitle = ""
    public var before = ""   // text before the cursor (up to 2,000 characters)
    public var after = ""    // text after the cursor (up to 500)
    public var visible = ""  // other text in the focused window (bounded walk)
    public var elements = 0
    public var ms = 0
    public var complete = false  // the window walk finished inside the budget

    public var allText: String { [windowTitle, before, after, visible].filter { !$0.isEmpty }.joined(separator: "\n") }

    /// `context` setting: on (default) | app-only (the focused field only, no window walk) | off.
    public static func gather(app: NSRunningApplication?, budget: TimeInterval = 0.15, settings: Settings = .shared) -> ScreenContext? {
        let mode = settings.string(.context)
        guard mode != "off", let app, Inserter.isTrusted, !Privacy.isPrivate(app: app) else { return nil }
        let started = Date()
        var ctx = ScreenContext()
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.05)  // a hung app must not hold the budget
        if let window: AXUIElement = copy(appElement, kAXFocusedWindowAttribute) {
            ctx.windowTitle = copy(window, kAXTitleAttribute) ?? ""
            if mode == "on" {
                var budgetLeft = 4_000
                var count = 0
                ctx.complete = walk(window, chars: &budgetLeft, count: &count, deadline: started.addingTimeInterval(budget), into: &ctx.visible)
                ctx.elements = count
            }
        }
        if let field = Inserter.focusedElement(in: app), let cursor = Inserter.textBeforeCursor(field) {
            ctx.before = String(cursor.before.suffix(2_000))
            if let value = Inserter.value(of: field) {
                let afterStart = value.utf16.index(value.utf16.startIndex, offsetBy: min(value.utf16.count, cursor.before.utf16.count + cursor.selected))
                ctx.after = String(String(value.utf16[afterStart...]) ?? "").prefix(500).description
            }
        }
        ctx.ms = Int(Date().timeIntervalSince(started) * 1000)
        return ctx
    }

    static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static let maxElements = 1_500

    /// Depth-first over the window, last child first, so the newest messages and the text near the input come before
    /// sidebars and toolbars: static text, headings, links and text fields, up to `chars` characters and
    /// `maxElements` elements, until the deadline. Buttons and menus are interface, not content. Secure text fields
    /// are skipped. Returns whether it finished.
    static func walk(_ element: AXUIElement, chars: inout Int, count: inout Int, deadline: Date, into out: inout String) -> Bool {
        guard chars > 0, count < maxElements, Date() < deadline else { return false }
        count += 1
        let role: String = copy(element, kAXRoleAttribute) ?? ""
        let subrole: String = copy(element, kAXSubroleAttribute) ?? ""
        if subrole == "AXSecureTextField" || role == "AXSecureTextField" { return true }
        if ["AXStaticText", "AXHeading", "AXLink", "AXTextField", "AXTextArea"].contains(role) {
            let text: String = copy(element, kAXValueAttribute) ?? copy(element, kAXTitleAttribute) ?? copy(element, kAXDescriptionAttribute) ?? ""
            if !text.isEmpty {
                let piece = String(text.prefix(chars))
                out += (out.isEmpty ? "" : "\n") + piece
                chars -= piece.count
            }
        }
        let children: [AXUIElement] = copy(element, kAXVisibleChildrenAttribute) ?? copy(element, kAXChildrenAttribute) ?? []
        for child in children.reversed() {
            if !walk(child, chars: &chars, count: &count, deadline: deadline, into: &out) { return false }
        }
        return true
    }
}
