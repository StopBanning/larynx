import AppKit
import LarynxCore
import ServiceManagement
import SwiftUI

/// The settings window (PLAN-v1 D1): everything the menu and settings.json offer, in one place. Every control writes
/// the same settings.json the menu does and takes effect at once; the menu keeps the quick toggles.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Larynx Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Renders each pane off-screen to PNGs in `dir`, for checking the layout without showing a window.
@MainActor func snapshotSettings(to dir: String) {
    let panes: [(String, AnyView)] = [("general", AnyView(GeneralPane())), ("speech", AnyView(SpeechPane())),
                                      ("cleanup", AnyView(CleanupPane())), ("privacy", AnyView(PrivacyPane())), ("words", AnyView(WordsPane())),
                                      ("firstrun", AnyView(FirstRunView()))]
    FirstRunModel.shared.refresh()
    for (name, view) in panes {
        let host = NSHostingView(rootView: view.frame(width: 540, height: 760))
        host.frame = NSRect(x: 0, y: 0, width: 540, height: 760)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("settings-\(name).png"))
    }
}

/// One setting as a string binding: reads settings.json, writes it, and runs `apply` after a successful write.
@MainActor
private func setting(_ key: LarynxCore.Settings.Key, apply: @escaping (String) -> Void = { _ in }) -> Binding<String> {
    Binding(get: { LarynxCore.Settings.shared.string(key) },
            set: { value in
                do { try LarynxCore.Settings.shared.set(value, for: key); apply(value); SettingsModel.shared.refresh += 1 }
                catch { log("could not save \(key.rawValue): \(error)") }
            })
}

@MainActor
private func onOff(_ key: LarynxCore.Settings.Key, on: String = "on", off: String = "off", apply: @escaping (Bool) -> Void = { _ in }) -> Binding<Bool> {
    Binding(get: { LarynxCore.Settings.shared.string(key) == on },
            set: { value in
                do { try LarynxCore.Settings.shared.set(value ? on : off, for: key); apply(value); SettingsModel.shared.refresh += 1 }
                catch { log("could not save \(key.rawValue): \(error)") }
            })
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralPane().tabItem { Label("General", systemImage: "gearshape") }
            SpeechPane().tabItem { Label("Speech", systemImage: "waveform") }
            CleanupPane().tabItem { Label("Cleanup", systemImage: "wand.and.stars") }
            PrivacyPane().tabItem { Label("Privacy", systemImage: "lock") }
            WordsPane().tabItem { Label("Words", systemImage: "character.book.closed") }
        }
        .frame(minWidth: 540, minHeight: 520)
    }
}

/// Window state that isn't a plain settings.json value (no SwiftUI macros: this builds with the command-line tools).
@MainActor final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()
    @Published var keys = Set((activeHotkey?.keys ?? listenKeys).map(\.rawValue))
    @Published var login = SMAppService.mainApp.status == .enabled
    @Published var engineChoice = engine.rawValue
    @Published var refresh = 0  // bumped after a write so bindings re-read settings.json
}

private struct GeneralPane: View {
    @ObservedObject private var model = SettingsModel.shared
    private var keys: Set<String> { model.keys }
    var body: some View {
        Form {
            Section("Talk key") {
                ForEach(Hotkey.Key.allCases, id: \.rawValue) { key in
                    Toggle(key.label, isOn: Binding(
                        get: { keys.contains(key.rawValue) },
                        set: { on in
                            var next = keys
                            if on { next.insert(key.rawValue) } else { next.remove(key.rawValue) }
                            guard !next.isEmpty else { return }  // always keep one talk key
                            let ordered = Hotkey.Key.allCases.filter { next.contains($0.rawValue) }
                            guard (try? LarynxCore.Settings.shared.set(ordered.map(\.rawValue).joined(separator: ","), for: .keys)) != nil else { return }
                            activeHotkey?.keys = ordered
                            model.keys = next
                        }))
                }
                Text("Hold to talk, let go to paste. Pressing another key while holding cancels, so shortcuts still work.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Hands-free") {
                Toggle("Double-tap the talk key to keep recording", isOn: onOff(.handsFree) { activeHotkey?.doubleTapLocks = $0 })
                Picker("Hands-Free Key", selection: setting(.toggleKeys) { raw in
                    activeHotkey?.toggleKeys = Hotkey.Key(rawValue: raw).map { [$0] } ?? []
                }) {
                    Text("None").tag("")
                    ForEach(Hotkey.Key.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
            }
            Section("Pill") {
                Toggle("Show the pill and live words while you talk", isOn: onOff(.preview))
                Picker("Position", selection: setting(.pillPosition)) {
                    Text("Above the text field").tag("auto")
                    Text("Bottom of the screen").tag("bottom")
                }
                HStack {
                    Text("Glass")
                    Slider(value: Binding(get: { Double(LarynxCore.Settings.shared.string(.pillGlass)) ?? 25 },
                                          set: { v in
                                              try? LarynxCore.Settings.shared.set(String(Int(v)), for: .pillGlass)
                                              Pill.shared.previewGlass(v / 100)
                                          }), in: 0...100)
                    Text("Solid").foregroundStyle(.secondary)
                }
                Toggle("Say when a word was probably misheard", isOn: onOff(.doubtHint))
            }
            Section {
                Toggle("Open Larynx at login", isOn: Binding(get: { model.login }, set: { on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { log("login item: \(error)") }
                    model.login = SMAppService.mainApp.status == .enabled
                }))
            }
        }
        .formStyle(.grouped)
    }
}

private struct SpeechPane: View {
    @ObservedObject private var model = SettingsModel.shared
    var body: some View {
        Form {
            Section("Speech model") {
                Picker("Model", selection: Binding(get: { model.engineChoice }, set: { raw in
                    model.engineChoice = raw
                    let item = NSMenuItem(); item.representedObject = raw
                    MenuController.shared.chooseEngine(item)  // prepares the new model in the background, then restarts
                })) {
                    Text("Parakeet Ultra: most accurate, 25 languages").tag("ultra")
                    Text("Bark Clean: English, drops ums as it listens").tag("clean")
                    Text("Parakeet v3: 25 languages").tag("parakeet")
                    Text("Parakeet Unified: English").tag("unified")
                }
                Text("Switching loads the new model in the background (a minute or two the first time) and keeps using the current one until it's ready.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Microphone") {
                Picker("Keep the microphone open after a dictation", selection: setting(.micWarm)) {
                    Text("Off (close it at once)").tag("0")
                    Text("10 seconds").tag("10")
                    Text("30 seconds").tag("30")
                    Text("2 minutes").tag("120")
                }
                Text("An open microphone starts instantly, so the first word is never cut off. While it waits, sound only passes through a tiny buffer in memory and is never kept; macOS shows its microphone dot.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Vocabulary") {
                Toggle("Listen for names from your projects, dictionary and vocabulary", isOn: onOff(.vocabulary))
                Toggle("Include common developer names (GitHub, Supabase…)", isOn: onOff(.devTerms))
                Toggle("Learn from fixes (repeats and edits)", isOn: onOff(.learn))
            }
        }
        .formStyle(.grouped)
    }
}

private struct CleanupPane: View {
    @ObservedObject private var model = SettingsModel.shared
    var body: some View {
        Form {
            Section("Cleanup") {
                Toggle("AI rewrite for corrections in Mail and Messages (Apple's on-device model)", isOn: onOff(.rewrite, on: "auto"))
                Toggle("Fit dictations to the text already in the field", isOn: onOff(.fitToField))
                Toggle("Check each paste arrived, and insert another way if it didn't", isOn: onOff(.verifyPaste))
            }
            Section("Stages") {
                ForEach([(LarynxCore.Settings.Key.dictionaryStage, "Your dictionary"), (.tidyStage, "Tidy (ums, repeats, false starts)"),
                         (.numbersStage, "Numbers as digits"), (.rewriteStage, "AI rewrite")], id: \.0.rawValue) { key, title in
                    Picker(title, selection: setting(key)) {
                        Text("On").tag("on"); Text("Shadow (record only)").tag("shadow"); Text("Off").tag("off")
                    }
                }
                Text(verbatim: "Shadow runs a stage and records what it would change, without changing your text: larynx mine --shadow")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PrivacyPane: View {
    @ObservedObject private var model = SettingsModel.shared
    var body: some View {
        Form {
            Section("History") {
                Toggle("Keep a history of dictations on this Mac", isOn: onOff(.history))
                Picker("Keep text for", selection: setting(.historyDays)) {
                    Text("7 days").tag("7"); Text("30 days").tag("30"); Text("90 days").tag("90"); Text("1 year").tag("365")
                }
                Picker("Keep recordings for", selection: setting(.keepAudio)) {
                    Text("Don't keep").tag("off"); Text("7 days").tag("7"); Text("30 days").tag("30"); Text("90 days").tag("90")
                }
            }
            Section("Screen context") {
                Picker("Read names on screen", selection: setting(.context)) {
                    Text("Only the text field").tag("app-only"); Text("Field and window (may slow some apps)").tag("on"); Text("Off").tag("off")
                }
                Text("Used to spell names the way they appear on screen. Read at each press, kept in memory for that one dictation, never saved or logged. Password fields and password managers are never read.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Nothing you say leaves this Mac. Password fields and the apps in privacy.json are never recorded or kept.")
                    .font(.callout)
                Button("Open privacy details") { NSWorkspace.shared.open(URL(string: "https://github.com/StopBanning/larynx/blob/main/docs/PRIVACY.md")!) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct WordsPane: View {
    var body: some View {
        Form {
            Section("Your words") {
                Button("Edit Dictionary…") { MenuController.shared.openDictionary() }
                Button("Edit Vocabulary…") { MenuController.shared.openVocabulary() }
                Button("Edit Snippets…") { MenuController.shared.openSnippets() }
                Text("Dictionary: what Larynx hears → what it types. Vocabulary: names to listen for. Snippets: say a cue, paste saved text.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
