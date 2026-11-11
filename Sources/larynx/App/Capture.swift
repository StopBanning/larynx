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
