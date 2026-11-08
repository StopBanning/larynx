import AppKit

/// A small floating pill at the bottom of the screen that shows the words as you speak.
/// It is a non-activating panel that ignores the mouse, so it never takes focus from the app you are dictating into.
@MainActor
final class Pill {
    static let shared = Pill()
    /// `defaults write com.automatedworkflow.larynx preview off` turns it off.
    nonisolated static var enabled: Bool { UserDefaults.standard.string(forKey: "preview") != "off" }

    private var panel: NSPanel?
    private var label: NSTextField?

    func show(_ text: String) {
        guard Pill.enabled else { return }
        let (panel, label) = build()
        label.stringValue = text
        let maxWidth: CGFloat = 560
        let width = min(maxWidth, max(160, label.intrinsicContentSize.width + 36))
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: area.midX - width / 2, y: area.minY + 64, width: width, height: 38), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func build() -> (NSPanel, NSTextField) {
        if let panel, let label { return (panel, label) }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 38),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 19
        blur.layer?.masksToBounds = true
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingHead  // keep the newest words visible
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -18),
            label.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
        ])
        panel.contentView = blur
        self.panel = panel
        self.label = label
        return (panel, label)
    }
}
