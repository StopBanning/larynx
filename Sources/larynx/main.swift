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
    freopen(logURL.path, "a", stderr)
    setvbuf(stderr, nil, _IOLBF, 0)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Dictionary.ensureExists()
    Vocabulary.ensureExists()
    Snippets.ensureExists()
    makeMenuBarItem()
    MenuController.shared.setUpLoginItemOnce()
    Task { await runListen(keys: listenKeys) }
    app.run()
}
runCommand()
RunLoop.main.run()
