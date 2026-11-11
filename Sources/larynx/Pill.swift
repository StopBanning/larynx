import AppKit
import AVFoundation
import LarynxCore

/// The floating pill at the bottom of the screen: where your words are going, a waveform that moves with your voice,
/// and the words as you say them. It is a non-activating panel that ignores the mouse, so it never takes focus from
/// the app you are dictating into. Liquid Glass on macOS 26, a blurred HUD before that.
///
/// States: listening (live waveform, live words), transcribing (the waveform turns into a travelling shimmer and the
/// last words stay put), and messages (copied, heard nothing, no sound from the mic, recovered, learned).
@MainActor
final class Pill {
    static let shared = Pill()
    /// `preview: off` in settings.json (or `defaults write com.automatedworkflow.larynx preview off`) turns it off.
    nonisolated static var enabled: Bool { Settings.shared.string(.preview) != "off" }

    enum Phase { case hidden, listening, transcribing, message }
    /// The panel's window number, for `screencapture -l` (the demo prints it).
    var windowNumber: Int? { panel?.windowNumber }
    var frame: NSRect? { panel?.frame }

    private static let maxWidth: CGFloat = 520
    private static let pad = NSSize(width: 14, height: 10)
    private static let rowHeight: CGFloat = 24

    private var panel: NSPanel?
    private var content: PillContent?
    private var timer: Timer?
    private var phase: Phase = .hidden
    private var level: (() -> Float)?
    private var listenStarted = Date()
    private var loudest: Float = 0
    private var warnedSilence = false
    private var words = ""
    private var hideWork: DispatchWorkItem?
    /// The focused text field's frame for this dictation; the pill sits just above it.
    private var anchor: NSRect?

    // MARK: States

    /// Recording started: shows the target app's icon and a live waveform.
    func listen(app: NSRunningApplication?, privateField: Bool, field: NSRect? = nil, level: @escaping () -> Float) {
        guard Pill.enabled else { return }
        let content = build()
        cancelHide()
        phase = .listening
        self.level = level
        listenStarted = Date()
        loudest = 0
        warnedSilence = false
        words = ""
        anchor = Settings.shared.string(.pillPosition) == "auto" ? field : nil
        content.setApp(app?.icon, name: app?.localizedName, privateField: privateField)
        content.setSymbol(nil)
        content.wave.mode = .live
        content.wave.reset()
        layout(text: "", dim: false)
        startTimer()
        appear()
    }

    /// The live transcript so far.
    func words(_ text: String) {
        guard Pill.enabled, phase == .listening else { return }
        words = text
        layout(text: text, dim: false)
    }

    /// Key released: the waveform becomes a shimmer while the final transcript is made; the last words stay.
    func transcribing() {
        guard Pill.enabled, phase == .listening else { return }
        phase = .transcribing
        content?.wave.mode = .thinking
        layout(text: words, dim: true)
    }

    /// A short notice with an optional SF Symbol. Hides itself after `seconds` (nil keeps it up).
    func message(_ text: String, symbol: String? = nil, tint: NSColor? = nil, seconds: Double? = nil) {
        guard Pill.enabled else { return }
        let content = build()
        cancelHide()
        phase = .message
        anchor = nil  // notices are about Larynx, not the field: bottom of the screen
        content.wave.mode = .hidden
        content.setApp(nil, name: nil, privateField: false)
        content.setSymbol(symbol, tint: tint)
        layout(text: text, dim: false)
        startTimer()
        appear()
        if let seconds { hide(after: seconds) }
    }

    /// Kept for callers that just want words on screen (demo, learned words).
    func show(_ text: String) { phase == .listening ? words(text) : message(text) }

    func hide() {
        cancelHide()
        phase = .hidden
        timer?.invalidate(); timer = nil
        guard let panel, panel.isVisible else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in if self?.phase == .hidden { panel.orderOut(nil) } }
        })
    }

    func hide(after seconds: Double) {
        cancelHide()
        let work = DispatchWorkItem { [weak self] in Task { @MainActor in self?.hide() } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelHide() { hideWork?.cancel(); hideWork = nil }

    // MARK: Animation

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let content else { return }
        if phase == .listening, let level {
            let value = level()
            loudest = max(loudest, value)
            content.wave.push(value)
            // A muted or wrong microphone: say so while there's still time to fix it, instead of typing nothing.
            if !warnedSilence, Date().timeIntervalSince(listenStarted) > 1.5, loudest < 0.002 {
                warnedSilence = true
                let mic = AVCaptureDevice.default(for: .audio)?.localizedName ?? "the microphone"
                content.setSymbol("mic.slash", tint: .systemOrange)
                layout(text: "No sound from \(mic)", dim: false)
            } else if warnedSilence, loudest >= 0.002, words.isEmpty {
                content.setSymbol(nil)
                layout(text: "", dim: false)
            }
        }
        content.wave.step()
    }

    private func appear() {
        guard let panel else { return }
        if !panel.isVisible || panel.alphaValue < 1 {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                panel.alphaValue = 1
            } else {
                if !panel.isVisible { panel.alphaValue = 0 }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    panel.animator().alphaValue = 1
                }
            }
        }
        panel.orderFrontRegardless()
    }

    // MARK: Layout

    /// Sizes the pill around its text (up to three lines, newest words kept) and grows upward from a fixed bottom edge.
    private func layout(text: String, dim: Bool) {
        guard let panel, let content else { return }
        let font = content.label.font!
        func measure(_ t: String, _ w: CGFloat) -> NSSize {
            let r = (t as NSString).boundingRect(with: NSSize(width: w, height: 10_000),
                                                 options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
            return NSSize(width: ceil(r.width), height: ceil(r.height))
        }
        let maxText = Pill.maxWidth - content.orbWidth - 10 - 6
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        var shown = text
        while measure(shown, maxText).height > lineHeight * 3 + 2, shown.count > 20 {  // keep the newest words
            let rest = shown.drop(while: { $0 == "…" })
            guard let space = rest.dropFirst(8).firstIndex(of: " ") else { break }
            shown = "…" + rest[rest.index(after: space)...]
        }
        let measured = shown.isEmpty ? NSSize.zero : measure(shown, maxText)
        content.label.stringValue = shown
        content.label.textColor = dim ? .secondaryLabelColor : .labelColor
        content.text = shown.isEmpty ? .zero : NSSize(width: min(maxText, measured.width) + 6, height: measured.height)
        let size = content.size
        let frame = place(width: ceil(size.width), height: ceil(size.height))
        let animate = panel.isVisible && panel.alphaValue > 0 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)  // quick, soft landing
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
                content.arrange(in: frame.size, animated: true)
            }
        } else {
            panel.setFrame(frame, display: true)
            content.arrange(in: frame.size, animated: false)
        }
    }

    /// Just above the focused field when it's a normal-sized input (a chat box, a search field), centred on it and kept
    /// on screen; below it when there's no room above. Tall document areas and unknown fields: bottom of the screen.
    private func place(width: CGFloat, height: CGFloat) -> NSRect {
        if let field = anchor, field.height <= 220,
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(field) }) {
            let area = screen.visibleFrame
            let x = min(max(field.midX - width / 2, area.minX + 8), area.maxX - width - 8).rounded()
            let above = field.maxY + 8
            if above + height <= area.maxY - 8 { return NSRect(x: x, y: above, width: width, height: height) }
            let below = field.minY - 8 - height
            if below >= area.minY + 8 { return NSRect(x: x, y: below, width: width, height: height) }
        }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? .zero
        return NSRect(x: (area.midX - width / 2).rounded(), y: area.minY + 56, width: width, height: height)
    }

    private func build() -> PillContent {
        if let content { return content }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        if #available(macOS 26.0, *) { panel.hasShadow = false } else { panel.hasShadow = true }  // glass casts its own
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.sharingType = .readOnly  // allow screen capture
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let content = PillContent(pad: Pill.pad)
        panel.contentView = content.root
        self.panel = panel
        self.content = content
        return content
    }
}

/// The views inside the pill: one capsule of glass (a blurred HUD before macOS 26) holding the app icon and waveform
/// (or a status symbol) on the left and the words on the right. It grows smoothly as words arrive.
@MainActor
final class PillContent {
    static let height: CGFloat = 44
    let root: NSView
    let icon = NSImageView()
    let lock = NSImageView()
    let symbol = NSImageView()
    let wave = Waveform()
    let label = NSTextField(wrappingLabelWithString: "")
    private let orbContent = NSView()
    private let bubbleContent = NSView()
    private var orb: NSView!
    private var bubble: NSView!
    private let pad: NSSize
    private var showsIcon = false
    private var showsSymbol = false
    /// Size of the text inside the bubble; zero hides the bubble.
    var text: NSSize = .zero

    var orbWidth: CGFloat { pad.width * 2 + max(20, leadingWidth) }
    var leadingWidth: CGFloat {
        var w: CGFloat = 0
        if showsIcon { w += 20 }
        if wave.mode != .hidden { w += (showsIcon ? 8 : 0) + wave.preferredWidth }
        if showsSymbol { w += (w > 0 ? 8 : 0) + 18 }
        return w
    }
    private var bubbleSize: NSSize {
        text == .zero ? .zero : NSSize(width: text.width + pad.width * 2, height: max(PillContent.height, text.height + pad.height * 2))
    }
    var size: NSSize {
        let b = bubbleSize
        guard b != .zero else { return NSSize(width: orbWidth, height: PillContent.height) }
        return NSSize(width: orbWidth - pad.width + 10 + b.width - pad.width, height: max(PillContent.height, b.height))
    }

    init(pad: NSSize) {
        self.pad = pad
        for v in [icon, lock, symbol] { v.imageScaling = .scaleProportionallyUpOrDown; orbContent.addSubview(v) }
        lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Not saved: private field")
        lock.contentTintColor = .secondaryLabelColor
        orbContent.addSubview(wave)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .left
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byWordWrapping
        bubbleContent.addSubview(label)
        if #available(macOS 26.0, *) {
            // One piece of glass: the icon, the waveform and the words share a single continuous shape.
            let glass = NSGlassEffectView()
            glass.style = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? .regular : .clear
            glass.cornerRadius = PillContent.height / 2
            let canvas = NSView()
            orb = orbContent
            bubble = bubbleContent
            canvas.addSubview(bubble)
            canvas.addSubview(orb)
            glass.contentView = canvas
            root = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.masksToBounds = true
            orb = orbContent
            bubble = bubbleContent
            blur.addSubview(bubble)
            blur.addSubview(orb)
            root = blur
        }
    }

    func setApp(_ image: NSImage?, name: String?, privateField: Bool) {
        icon.image = image
        icon.toolTip = name
        icon.setAccessibilityLabel(name.map { "Dictating into \($0)" })
        showsIcon = image != nil
        lock.isHidden = !privateField
    }

    func setSymbol(_ name: String?, tint: NSColor? = nil) {
        symbol.image = name.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        symbol.contentTintColor = tint ?? .labelColor
        showsSymbol = symbol.image != nil
    }

    /// Manual layout: the pill changes size several times a second; Auto Layout would only add work.
    func arrange(in total: NSSize, animated: Bool) {
        // The icon and waveform sit on the left, centred on the whole capsule; the words fill the rest.
        let h = total.height
        let orbFrame = NSRect(x: 0, y: 0, width: orbWidth, height: h)
        let b = bubbleSize
        let bubbleX = orbWidth - pad.width + 10 - pad.width
        let bubbleFrame = b == .zero
            ? NSRect(x: orbWidth - pad.width, y: 0, width: 0, height: h)
            : NSRect(x: bubbleX, y: 0, width: b.width, height: h)
        if #available(macOS 26.0, *), let glass = root as? NSGlassEffectView {
            glass.cornerRadius = min(h / 2, 22)
            glass.contentView?.frame = NSRect(origin: .zero, size: total)
        } else {
            root.layer?.cornerRadius = min(h / 2, 22)
        }
        let setFrame: (NSView, NSRect) -> Void = { v, r in if animated { v.animator().frame = r } else { v.frame = r } }
        setFrame(orb, orbFrame)
        setFrame(bubble, bubbleFrame)
        bubble.alphaValue = b == .zero ? 0 : 1

        // Inside the orb: [icon][waveform][symbol], vertically centred.
        let midY = h / 2
        var x = pad.width
        icon.isHidden = !showsIcon
        if showsIcon {
            icon.frame = NSRect(x: x, y: midY - 10, width: 20, height: 20)
            lock.frame = NSRect(x: x + 11, y: midY - 11, width: 10, height: 10)
            x += 20
        } else { lock.isHidden = true }
        wave.isHidden = wave.mode == .hidden
        if !wave.isHidden {
            if showsIcon { x += 8 }
            wave.frame = NSRect(x: x, y: midY - 12, width: wave.preferredWidth, height: 24)
            x += wave.preferredWidth
        }
        symbol.isHidden = !showsSymbol
        if showsSymbol {
            if x > pad.width { x += 8 }
            symbol.frame = NSRect(x: x, y: midY - 9, width: 18, height: 18)
        }
        // Inside the bubble: the words, vertically centred.
        label.isHidden = b == .zero
        label.frame = NSRect(x: pad.width, y: (bubbleFrame.height - text.height) / 2, width: text.width, height: text.height)
    }
}

/// A scrolling waveform of the voice's loudness, newest on the right, drawn as rounded bars mirrored around the
/// middle. While transcribing it becomes a shimmer that travels across the bars.
@MainActor
final class Waveform: NSView {
    enum Mode { case live, thinking, hidden }
    var mode: Mode = .live { didSet { if mode != oldValue { phase = 0 } } }
    private static let count = 22
    private static let barWidth: CGFloat = 3
    private static let gap: CGFloat = 2.5
    var preferredWidth: CGFloat { CGFloat(Waveform.count) * (Waveform.barWidth + Waveform.gap) - Waveform.gap }

    private var history = [CGFloat](repeating: 0, count: Waveform.count)
    private var bars: [CALayer] = []
    private var smoothed: CGFloat = 0
    private var phase: CGFloat = 0
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for _ in 0..<Waveform.count {
            let bar = CALayer()
            bar.cornerRadius = Waveform.barWidth / 2
            layer?.addSublayer(bar)
            bars.append(bar)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel("Listening")
    }
    required init?(coder: NSCoder) { fatalError() }

    func reset() { history = .init(repeating: 0, count: Waveform.count); smoothed = 0; step() }

    /// One loudness reading (RMS). Mapped to decibels so quiet speech still moves and shouting doesn't clip.
    func push(_ rms: Float) {
        let db = 20 * log10(max(rms, 1e-5))
        let target = CGFloat(min(1, max(0, (db + 52) / 40)))  // -52 dB (room) ... -12 dB (loud)
        smoothed = target > smoothed ? smoothed + (target - smoothed) * 0.6 : smoothed + (target - smoothed) * 0.25
        if reduceMotion { history = .init(repeating: smoothed, count: Waveform.count) }
        else { history.removeFirst(); history.append(smoothed) }
    }

    /// Redraws the bars; called 30 times a second.
    func step() {
        guard mode != .hidden else { return }
        phase += 1
        let h = bounds.height
        let color = (effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.white : NSColor.black)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            let value: CGFloat
            var alpha: CGFloat = 0.85
            switch mode {
            case .live:
                // Older bars fade slightly so the eye reads time flowing right to left.
                value = history[i]
                alpha = 0.45 + 0.45 * CGFloat(i) / CGFloat(Waveform.count - 1)
            case .thinking:
                let wave = reduceMotion ? 0.5 : (sin((CGFloat(i) * 0.55) - phase * 0.28) + 1) / 2
                value = 0.12 + 0.30 * wave
                alpha = 0.35 + 0.45 * wave
            case .hidden:
                value = 0
            }
            let barHeight = max(Waveform.barWidth, value * h)
            bar.frame = CGRect(x: CGFloat(i) * (Waveform.barWidth + Waveform.gap), y: (h - barHeight) / 2,
                               width: Waveform.barWidth, height: barHeight)
            bar.backgroundColor = color.withAlphaComponent(alpha).cgColor
        }
        CATransaction.commit()
    }
}
