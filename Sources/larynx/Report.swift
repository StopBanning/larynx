import AppKit
import AVFoundation
import LarynxCore

/// "Send a Report…" in the menu: writes "Larynx report.txt" next to the log (~/Library/Logs; the Desktop would make
/// macOS ask for permission), shows it in Finder and opens a Mail message with it attached and no one in To:.
/// BugReport says what's in it and what never is.
enum ReportSender {
    static var file: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Larynx report.txt") }

    static func appLines() -> String {
        let s = Settings.shared
        let mic: String = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: "allowed"
        case .denied: "denied"
        case .restricted: "restricted"
        default: "not asked yet"
        }
        return """
            Larynx \(Links.version) for Mac
            Speech model: \(s.string(.engine))
            Meeting notes by: Claude \(s.string(.meetingClaude))
            Claude Code: \(ClaudeCode.isInstalled ? "installed" : "not found")
            Claude key saved: \(ClaudeKey.isSet ? "yes" : "no")
            Microphone permission: \(mic)
            Accessibility permission: \(AXIsProcessTrusted() ? "allowed" : "not allowed")
            """
    }

    static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buffer)
    }

    static func computerLines() -> String {
        let p = ProcessInfo.processInfo
        let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage.map { String(format: "%.1f GB", Double($0) / 1e9) } ?? "?"
        let mics = AudioDevices.inputs().map { "  " + $0.name }
        return ([
            "macOS: \(p.operatingSystemVersionString)",
            "Model: \(sysctl("hw.model")), \(sysctl("machdep.cpu.brand_string"))",
            "Memory: \(p.physicalMemory / 1_073_741_824) GB",
            "Free on the startup disk: \(free)",
            "Microphones:",
        ] + (mics.isEmpty ? ["  none"] : mics)).joined(separator: "\n")
    }

    @MainActor static func send() {
        let logText = (try? String(contentsOfFile: NSHomeDirectory() + "/Library/Logs/Larynx.log", encoding: .utf8)) ?? ""
        let text = BugReport.build(app: appLines(), computer: computerLines(), log: logText, meetings: Array(MeetingStore.all().prefix(10)))
        do {
            try Data(text.utf8).write(to: file, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.messageText = "The report couldn't be saved"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        log("report: saved, \(text.count) characters")
        NSWorkspace.shared.activateFileViewerSelecting([file])
        if let mail = NSSharingService(named: .composeEmail) {
            mail.subject = "Larynx report"
            if mail.canPerform(withItems: [file]) { mail.perform(withItems: [file]) }
        }
    }
}
