import Foundation
import LarynxCore
import LarynxText

/// `larynx meeting --you mic.wav [--them call.wav] [--summary auto|claude|on-device|private-cloud|all|none] [--json] [--save]`
///
/// Meeting mode from files (docs/dev/MEETING.md): the same transcript and notes the app makes from a live meeting, so
/// tests and benchmarks need no microphone, no call and no permission prompt. Prints Markdown, or JSON with --json.
func runMeeting() async {
    if let c = option("--claude") { ClaudeNotes.choiceOverride = c }
    // --from meeting.json: notes for a transcript already made (no audio, no speech model): for tuning the notes.
    if let from = option("--from") {
        do {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let data = try Data(contentsOf: URL(fileURLWithPath: (from as NSString).expandingTildeInPath))
            struct Saved: Decodable { let meeting: Meeting }
            var meeting = try (try? decoder.decode(Saved.self, from: data).meeting) ?? decoder.decode(Meeting.self, from: data)
            // --echo-report: which "You" lines the echo filter takes out (the call picked up from the speakers).
            if args.contains("--echo-report") {
                let kept = MeetingEcho.remove(meeting.segments)
                for s in meeting.segments where s.speaker == "You" {
                    print("\(kept.contains(s) ? "keep" : "echo") \(Meeting.clock(s.start)) \(s.text)")
                }
                exit(0)
            }
            meeting.segments = MeetingEcho.remove(meeting.segments)
            let model = MeetingSummarizer.Model.chosen(option("--summary") ?? "auto")
            let notes = try await MeetingSummarizer.summarize(meeting, model: model)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(notes), as: UTF8.self))
            exit(0)
        } catch { FileHandle.standardError.write(Data("larynx meeting: \(error)\n".utf8)); exit(1) }
    }
    guard let youPath = option("--you") else {
        FileHandle.standardError.write(Data("usage: larynx meeting --you mic.wav [--them call.wav] [--summary auto|claude|on-device|private-cloud|all|none] [--json] [--save]\n".utf8))
        exit(2)
    }
    do {
        let started = Date()
        let you = try loadAudioFile(URL(fileURLWithPath: (youPath as NSString).expandingTildeInPath))
        let them = try option("--them").map { try loadAudioFile(URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)) }
        try await Loader.shared.task.value
        let loaded = Date()
        // The audio goes in the way a live meeting delivers it: a second at a time, with the transcript caught up every
        // 20 seconds. So "stop" here costs what it costs in the app: the last few seconds and the notes.
        let session = MeetingSession { samples in try await transcriber.transcribe(samples) }
        let second = Int(Recorder.sampleRate)
        let longest = max(you.count, them?.count ?? 0)
        var at = 0
        while at < longest {
            let end = min(longest, at + second)
            if at < you.count { await session.append(Array(you[at..<min(end, you.count)]), side: "You") }
            if let them, at < them.count { await session.append(Array(them[at..<min(end, them.count)]), side: "On the call") }
            at = end
            if at % (20 * second) == 0 { try await session.step() }
        }
        let stopped = Date()
        var segments = try await session.finish()
        // Who is who on the call: speaker separation, then names from how people were addressed.
        if let them, option("--speakers") != "off" {
            let diarizer = MeetingDiarizer()
            try await diarizer.load(modelsDir: modelsDir)
            let turns = try await diarizer.turns(them)
            segments = try await MeetingSpeakers.label(segments, callSide: "On the call", turns: turns, callAudio: them) { samples in
                try await transcriber.transcribe(samples)
            }
            segments = MeetingSpeakers.name(segments)
        }
        let transcribed = Date()
        let duration = Double(longest) / Recorder.sampleRate
        var meeting = Meeting(id: MeetingStore.newID(started), started: started, duration: duration, segments: segments)

        let which = option("--summary") ?? "auto"
        let models: [MeetingSummarizer.Model] = which == "both" || which == "all" ? MeetingSummarizer.Model.allCases
            : which == "none" ? [] : [MeetingSummarizer.Model.chosen(which)]
        var allNotes: [MeetingNotes] = []
        var failures: [String: String] = [:]
        for model in models {
            do { allNotes.append(try await MeetingSummarizer.summarize(meeting, model: model)) }
            catch { failures[model.rawValue] = "\(error)" }
        }
        meeting.notes = allNotes.first
        if args.contains("--save") { try MeetingStore.save(meeting) }

        let timing: [String: Double] = [
            "load": loaded.timeIntervalSince(started), "transcribe": transcribed.timeIntervalSince(loaded),
            "finish": transcribed.timeIntervalSince(stopped), "audio": duration,
        ]
        if args.contains("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            struct Output: Encodable { let meeting: Meeting; let notes: [MeetingNotes]; let failures: [String: String]; let timing: [String: Double] }
            print(String(decoding: try encoder.encode(Output(meeting: meeting, notes: allNotes, failures: failures, timing: timing)), as: UTF8.self))
        } else {
            for notes in allNotes {
                var m = meeting; m.notes = notes
                print("<!-- \(notes.model), \(String(format: "%.1f", notes.seconds)) s -->")
                print(m.markdown)
                print()
            }
            if allNotes.isEmpty { print(meeting.markdown) }
            for (model, why) in failures { FileHandle.standardError.write(Data("\(model): \(why)\n".utf8)) }
            FileHandle.standardError.write(Data(String(format: "%.0f s of audio, transcribed in %.1f s\n", duration, timing["transcribe"]!).utf8))
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("larynx meeting: \(error)\n".utf8))
        exit(1)
    }
}
