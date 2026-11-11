import AppKit
import LarynxText

extension CleanupMode {
    /// The app that will receive the text right now.
    public static func frontmost() -> (bundleID: String?, mode: CleanupMode) {
        let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return (id, forApp(bundleID: id))
    }
}
