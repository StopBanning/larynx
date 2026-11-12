import AppKit
import Foundation
import LarynxCore

/// `larynx capture-window [--seconds n]`: a small window with one text view, the only place live tests paste into.
/// Prints JSON lines: {"event":"ready","pid":...} once it has focus, then {"event":"text","ms":...,"text":...} on
/// every change (ms since ready). Quits after `--seconds` (default 60) or when stdin closes.
@MainActor
final class CaptureWindow: NSObject, NSTextViewDelegate {
    static let shared = CaptureWindow()
    private var window: NSWindow?
    private var ready = Date()

    func run(seconds: Double, prefill: String = "") {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        // An Edit menu, as every real app has: on macOS ⌘V reaches a text view through the menu's key equivalents.
        let main = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = NSMenu(); main.addItem(appItem)
        appItem.submenu?.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let editItem = NSMenuItem(); let editMenu = NSMenu(title: "Edit"); editItem.submenu = editMenu; main.addItem(editItem)
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        app.mainMenu = main
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 160), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Larynx test capture (safe to close)"
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        let text = NSTextView(frame: scroll.bounds)
        text.isRichText = false
        text.font = .systemFont(ofSize: 13)
        text.string = prefill  // --prefill: text already in the field, cursor at its end (for fit-to-field tests)
        text.setSelectedRange(NSRange(location: (prefill as NSString).length, length: 0))
        text.delegate = self
        text.setAccessibilityIdentifier("larynx-capture")
        scroll.documentView = text
        window.contentView = scroll
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(text)
        // Ready once this process is really in front with the text view focused (checked from the run loop, every 50 ms
        // for up to 2 s).
        waitForFront(tries: 40)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
        // Quit when the driving test goes away, if it is connected by a pipe. Launched through `open` (how tests bring
        // it to the front) stdin is empty from the start, so then only --seconds and the test's own kill end it.
        var info = stat()
        if fstat(0, &info) == 0, (info.st_mode & S_IFMT) == S_IFIFO {
            DispatchQueue.global().async { while readLine() != nil {}; DispatchQueue.main.async { exit(0) } }
        }
        app.run()
    }

    private func waitForFront(tries: Int) {
        let me = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == me
        if front || tries <= 0 {
            ready = Date()
            emit(["event": "ready", "pid": Int(me), "front": front])
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { self.waitForFront(tries: tries - 1) } }
    }

    func textDidChange(_ notification: Notification) {
        guard let view = notification.object as? NSTextView else { return }
        emit(["event": "text", "ms": Int(Date().timeIntervalSince(ready) * 1000), "text": view.string])
    }
}
