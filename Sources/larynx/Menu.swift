import AppKit
import LarynxCore
import ServiceManagement

/// The menu bar menu: status, recent transcripts, and the settings people otherwise set with `defaults write`.
/// It is rebuilt each time it opens, so checkmarks always match the saved settings.
final class MenuController: NSObject, NSMenuDelegate {
    static let shared = MenuController()
    let statusLine = NSMenuItem(title: "Starting...", action: nil, keyEquivalent: "")
    /// The last 10 transcripts, newest first, for `history: off` (memory only, never written to disk).
    private var memoryRecent: [String] = []
    /// What the Recent submenu showed when it was last opened; clicks copy from here.
    private var shownRecent: [String] = []

    /// Recent comes from History when it's on, otherwise from this session's memory.
    var recent: [(text: String, recovered: Bool)] {
        guard settings.string(.history) != "off" else { return memoryRecent.map { ($0, false) } }
        return History.shared.recent(limit: 10).map { ($0.text, $0.flags.contains("recovered")) }
    }

    private let settings = Settings.shared

    @discardableResult private func save(_ value: String, for key: Settings.Key) -> Bool {
        do { try settings.set(value, for: key); return true }
        catch { log("could not save \(key.rawValue): \(error)"); return false }
    }

    func remember(_ text: String) {
        DispatchQueue.main.async {
            self.memoryRecent.insert(text, at: 0)
            if self.memoryRecent.count > 10 { self.memoryRecent.removeLast() }
        }
    }

    /// Turns on Open at Login the first time the app runs; after that the menu checkbox decides.
    func setUpLoginItemOnce() {
        guard !settings.bool(.loginItemSet) else { return }
        guard save("true", for: .loginItemSet) else { return }
        do { try SMAppService.mainApp.register(); log("added to login items") }
        catch { log("could not add to login items: \(error)") }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        let keys = activeHotkey?.keys ?? listenKeys
        let hint = NSMenuItem(title: "Hold " + keys.map(\.label).joined(separator: " or ") + " to talk", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())
        let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        let recent = self.recent
        shownRecent = recent.map(\.text)
        if recent.isEmpty {
            let none = NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            recentMenu.addItem(none)
        } else {
            let note = NSMenuItem(title: "Click to copy", action: nil, keyEquivalent: "")
            note.isEnabled = false
            recentMenu.addItem(note)
            for (i, (text, recovered)) in recent.enumerated() {
                let short = text.count > 60 ? String(text.prefix(57)) + "..." : text
                let title = recovered ? "Recovered: " + short : short
                let item = NSMenuItem(title: title, action: #selector(copyRecent(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                item.toolTip = text
                recentMenu.addItem(item)
            }
        }
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        if !Relearn.lastApplied.isEmpty {
            let undo = NSMenuItem(title: "Undo Learned: " + Relearn.describe(Relearn.lastApplied), action: #selector(undoLearned), keyEquivalent: "")
            undo.target = self
            menu.addItem(undo)
        }

        menu.addItem(.separator())
        menu.addItem(toggle("Live Preview", on: Pill.enabled, #selector(togglePreview)))
        menu.addItem(glassSliderItem())
        menu.addItem(toggle("AI Cleanup", on: autoRewrite, #selector(toggleRewrite)))
        let keyItem = NSMenuItem(title: "Talk Key", action: nil, keyEquivalent: "")
        let keyMenu = NSMenu()
        for key in Hotkey.Key.allCases {
            let item = NSMenuItem(title: key.label, action: #selector(toggleKey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key.rawValue
            item.state = keys.contains(key) ? .on : .off
            keyMenu.addItem(item)
        }
        keyItem.submenu = keyMenu
        menu.addItem(keyItem)
        menu.addItem(toggle("Double-Tap for Hands-Free", on: activeHotkey?.doubleTapLocks ?? (settings.string(.handsFree) != "off"),
                            #selector(toggleHandsFree)))
        let toggleItem = NSMenuItem(title: "Hands-Free Key", action: nil, keyEquivalent: "")
        let toggleMenu = NSMenu()
        let current = activeHotkey?.toggleKeys ?? []
        let none = NSMenuItem(title: "None", action: #selector(chooseToggleKey(_:)), keyEquivalent: "")
        none.target = self
        none.representedObject = ""
        none.state = current.isEmpty ? .on : .off
        toggleMenu.addItem(none)
        for key in Hotkey.Key.allCases where !keys.contains(key) {
            let item = NSMenuItem(title: key.label, action: #selector(chooseToggleKey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key.rawValue
            item.state = current.contains(key) ? .on : .off
            toggleMenu.addItem(item)
        }
        toggleItem.submenu = toggleMenu
        menu.addItem(toggleItem)
        let modelItem = NSMenuItem(title: "Speech Model", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        for (choice, title) in [(Engine.ultra, "Most accurate, 25 languages (Parakeet Ultra)"),
                                (Engine.clean, "English, drops ums as it listens (Bark Clean)"),
                                (Engine.parakeet, "25 languages (Parakeet v3)")] {
            let item = NSMenuItem(title: title, action: #selector(chooseEngine(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            item.state = engine == choice ? .on : .off
            modelMenu.addItem(item)
        }
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)
        menu.addItem(toggle("Open at Login", on: SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))

        menu.addItem(.separator())
        let dict = NSMenuItem(title: "Edit Dictionary...", action: #selector(openDictionary), keyEquivalent: "")
        dict.target = self
        menu.addItem(dict)
        let vocab = NSMenuItem(title: "Edit Vocabulary...", action: #selector(openVocabulary), keyEquivalent: "")
        vocab.target = self
        menu.addItem(vocab)
        let snippets = NSMenuItem(title: "Edit Snippets...", action: #selector(openSnippets), keyEquivalent: "")
        snippets.target = self
        menu.addItem(snippets)
        let reload = NSMenuItem(title: "Reload Vocabulary", action: #selector(reloadVocab), keyEquivalent: "")
        reload.target = self
        menu.addItem(reload)
        menu.addItem(NSMenuItem(title: "Quit Larynx", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// "Pill Glass": Clear on the left, Solid on the right; the pill appears while you drag.
    private func glassSliderItem() -> NSMenuItem {
        let item = NSMenuItem()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 48))
        let title = NSTextField(labelWithString: "Pill Glass")
        title.font = .menuFont(ofSize: 0)
        title.frame = NSRect(x: 20, y: 28, width: 220, height: 16)
        let left = NSTextField(labelWithString: "Clear")
        let right = NSTextField(labelWithString: "Solid")
        for label in [left, right] { label.font = .systemFont(ofSize: 10); label.textColor = .secondaryLabelColor }
        left.frame = NSRect(x: 20, y: 7, width: 34, height: 14)
        right.frame = NSRect(x: 214, y: 7, width: 34, height: 14)
        let slider = NSSlider(value: Double(Settings.shared.string(.pillGlass)) ?? 0, minValue: 0, maxValue: 100,
                              target: self, action: #selector(glassChanged(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 54, y: 5, width: 156, height: 20)
        slider.setAccessibilityLabel("Pill glass, from clear to solid")
        for v in [title, left, slider, right] { view.addSubview(v) }
        item.view = view
        return item
    }

    @objc func glassChanged(_ sender: NSSlider) {
        let value = Int(sender.doubleValue.rounded())
        // Saved on every change (a tiny atomic write): inside a menu the end of a drag isn't reliably reported.
        save(String(value), for: .pillGlass)
        Task { @MainActor in Pill.shared.previewGlass(Double(value) / 100) }
    }

    private func toggle(_ title: String, on: Bool, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    @objc func toggleHandsFree() {
        let on = !(activeHotkey?.doubleTapLocks ?? true)
        guard save(on ? "on" : "off", for: .handsFree) else { return }
        activeHotkey?.doubleTapLocks = on
    }

    /// One press starts hands-free, the next finishes: for a second macro-pad button.
    @objc func chooseToggleKey(_ sender: NSMenuItem) {
        let raw = sender.representedObject as? String ?? ""
        guard save(raw, for: .toggleKeys) else { return }
        activeHotkey?.toggleKeys = Hotkey.Key(rawValue: raw).map { [$0] } ?? []
        log("hands-free key: " + (raw.isEmpty ? "none" : raw))
    }

    @objc func undoLearned() { Task { @MainActor in Relearn.undoLast() } }

    @objc func copyRecent(_ sender: NSMenuItem) {
        guard shownRecent.indices.contains(sender.tag) else { return }
        Inserter.copyOnly(shownRecent[sender.tag])
        setStatus("Copied, press ⌘V")
    }

    @objc func togglePreview() {
        save(Pill.enabled ? "off" : "on", for: .preview)
    }

    @objc func toggleRewrite() {
        save(autoRewrite ? "off" : "auto", for: .rewrite)
    }

    @objc func toggleKey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = Hotkey.Key(rawValue: raw) else { return }
        var keys = activeHotkey?.keys ?? listenKeys
        if keys.contains(key) { keys.removeAll { $0 == key } } else { keys.append(key) }
        guard !keys.isEmpty else { return }  // always keep one talk key
        guard save(keys.map(\.rawValue).joined(separator: ","), for: .keys) else { return }
        activeHotkey?.keys = keys
        log("talk keys: " + keys.map(\.label).joined(separator: ", "))
    }

    /// The model being prepared after a Speech Model pick, so a second click doesn't start another.
    private var preparing: String?

    /// Switching models means loading a different one, so Larynx restarts itself. A model this app has never loaded
    /// takes the Neural Engine a minute or two to compile, so it is loaded here first, in the background, while the
    /// current model keeps taking dictation; the compiled copy is cached, so the restarted app loads it in under a second.
    @objc func chooseEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, raw != engine.rawValue, preparing == nil,
              let choice = Engine(rawValue: raw) else { return }
        preparing = raw
        log("speech model: \(raw), preparing it before restarting")
        setStatus("Preparing the new speech model (one time)...")
        nonisolated(unsafe) let controller = self  // only touched again on the main queue
        Task.detached {
            let started = Date()
            do {
                try await Transcriber().load(modelsDir: modelsDir, engine: choice)
            } catch {
                log("speech model \(raw) failed to load, staying on \(engine.rawValue): \(error)")
                DispatchQueue.main.async { controller.preparing = nil; setStatus("Could not load that model; still using the current one") }
                return
            }
            log("speech model \(raw) ready in \(ms(since: started)) ms")
            DispatchQueue.main.async {
                guard controller.save(raw, for: .engine) else { controller.preparing = nil; return }
                controller.restartWhenIdle()
            }
        }
    }

    /// Restarts once nothing has been recorded for 3 s in a row, so a dictation in progress is never cut off.
    private func restartWhenIdle(quiet: Int = 0) {
        if recorder.isRecording {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.restartWhenIdle(quiet: 0) }
            return
        }
        guard quiet >= 3 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.restartWhenIdle(quiet: quiet + 1) }
            return
        }
        log("speech model: \(preparing ?? "?"), restarting")
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { log("login item: \(error)") }
    }

    @objc func openSnippets() {
        Snippets.ensureExists()
        NSWorkspace.shared.open(Snippets.url)
    }

    @objc func openVocabulary() {
        Vocabulary.ensureExists()
        NSWorkspace.shared.open(Vocabulary.url)
    }

    @objc func reloadVocab() {
        setStatus("Loading vocabulary...")
        Task { await reloadVocabulary(); setStatus("Ready") }
    }

    @objc func openDictionary() {
        Dictionary.ensureExists()
        NSWorkspace.shared.open(Dictionary.url)
    }
}
