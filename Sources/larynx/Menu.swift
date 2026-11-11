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

        menu.addItem(.separator())
        menu.addItem(toggle("Live Preview", on: Pill.enabled, #selector(togglePreview)))
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
        let modelItem = NSMenuItem(title: "Speech Model", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        for (choice, title) in [(Engine.clean, "English, drops ums as it listens"), (Engine.parakeet, "25 languages (Parakeet v3)")] {
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

    private func toggle(_ title: String, on: Bool, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

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

    /// Switching models means loading a different one, so Larynx restarts itself.
    @objc func chooseEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, raw != engine.rawValue else { return }
        guard save(raw, for: .engine) else { return }
        log("speech model: \(raw), restarting")
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
