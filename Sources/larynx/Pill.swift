import AppKit

/// A small floating pill at the bottom of the screen that shows the words as you speak.
/// It is a non-activating panel that ignores the mouse, so it never takes focus from the app you are dictating into.
/// On macOS 26 it uses Liquid Glass; older systems get a blurred HUD material.
@MainActor
final class Pill {
    static let shared = Pill()
    /// `defaults write com.automatedworkflow.larynx preview off` turns it off.
    nonisolated static var enabled: Bool { UserDefaults.standard.string(forKey: "preview") != "off" }

    private static let maxWidth: CGFloat = 480
    private static let padding = NSSize(width: 20, height: 12)

    private var panel: NSPanel?
    private var label: NSTextField?

    func show(_ text: String) {
        guard Pill.enabled else { return }
        let (panel, label) = build()
        label.stringValue = text
        // Wrap to at most three lines and keep the newest words: the pill grows upward, never off the screen.
        let textWidth = Pill.maxWidth - Pill.padding.width * 2
        label.preferredMaxLayoutWidth = textWidth
        let one = label.sizeThatFits(NSSize(width: 10_000, height: 10_000))
        let width = min(Pill.maxWidth, max(150, one.width + Pill.padding.width * 2))
        let lineHeight = ceil(label.font!.boundingRectForFont.height)
        var shown = text
        var size = label.sizeThatFits(NSSize(width: width - Pill.padding.width * 2, height: 10_000))
        while size.height > lineHeight * 3 + 2, shown.count > 20 {  // drop the oldest words
            shown = "…" + shown.dropFirst(40)
            label.stringValue = shown
            size = label.sizeThatFits(NSSize(width: width - Pill.padding.width * 2, height: 10_000))
        }
        let height = ceil(size.height) + Pill.padding.height * 2
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: area.midX - width / 2, y: area.minY + 56, width: width, height: height), display: true)
        panel.contentView?.layer?.cornerRadius = min(height / 2, 22)
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func build() -> (NSPanel, NSTextField) {
        if let panel, let label { return (panel, label) }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.sharingType = .readOnly  // allow screen capture
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false

        let host = NSView()
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Pill.padding.width),
            label.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -Pill.padding.width),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.contentView = host
            glass.style = .regular
            glass.cornerRadius = 22
            panel.contentView = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.masksToBounds = true
            host.translatesAutoresizingMaskIntoConstraints = false
            blur.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: blur.leadingAnchor), host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
                host.topAnchor.constraint(equalTo: blur.topAnchor), host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            ])
            panel.contentView = blur
        }
        self.panel = panel
        self.label = label
        return (panel, label)
    }
}
