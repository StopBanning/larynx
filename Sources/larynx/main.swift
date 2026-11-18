import AppKit
import AVFoundation
import Foundation
import LarynxCore

// MARK: - Entry

setvbuf(stdout, nil, _IOLBF, 0)
_ = launchedAt  // pin the launch time now: spool files older than this were left by a crash
if inApp && args.isEmpty {
    // Launched as Larynx.app: log to ~/Library/Logs/Larynx.log and live in the menu bar.
    let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Larynx.log")
    // Past 5 MB the log keeps its newer half, so it never fills a disk.
    if let old = try? String(contentsOf: logURL, encoding: .utf8), let kept = BugReport.trimmed(old, max: 5_000_000) {
        try? Data(kept.utf8).write(to: logURL, options: .atomic)
    }
    freopen(logURL.path, "a", stderr)
    setvbuf(stderr, nil, _IOLBF, 0)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Dictionary.ensureExists()
    Vocabulary.ensureExists()
    Snippets.ensureExists()
    makeMenuBarItem()
    MainActor.assumeIsolated { FirstRun.shared.showIfNeeded() }
    MenuController.shared.setUpLoginItemOnce()
    Task { await runListen(keys: listenKeys) }
    app.run()
}
runCommand()
RunLoop.main.run()
