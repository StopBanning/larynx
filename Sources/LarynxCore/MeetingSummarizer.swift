import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Writes a meeting's notes with Apple's Foundation Models (docs/dev/MEETING.md). Guided generation returns a typed
/// structure, so the layout never breaks. Two models behind one switch:
/// - `.onDevice`: Apple's on-device model; nothing leaves the Mac. 8,192 tokens of context, so a long meeting is summarized
///   in parts and the parts combined.
/// - `.privateCloud`: Apple's Private Cloud Compute model (macOS 27); the transcript goes to Apple's private servers for
///   the summary only. 32,768 tokens: a two to three hour meeting in one pass.
public enum MeetingSummarizer {
    public enum Model: String, Sendable, CaseIterable {
        case onDevice = "on-device"
        case privateCloud = "private-cloud"
        case claude

        /// The model the `meetingSummary` setting names. `auto`: Claude when Claude Code or a Claude key is there, else
        /// the Mac's own.
        public static func chosen(_ setting: String) -> Model {
            if let model = Model(rawValue: setting) { return model }
            return MeetingSummarizer.isAvailable(.claude) ? .claude : .onDevice
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case unavailable(String)
        case empty
        public var description: String {
            switch self {
            case .unavailable(let why): return "The summary model isn't available: \(why)"
            case .empty: return "There was nothing to summarize."
            }
        }
    }

    static let instructions = """
        You write meeting notes for a busy person who was in the meeting and wants the result in plain English.
        Rules:
        - Use only what was said in the transcript. Never add facts, numbers, names or dates that were not said.
        - Use people's names when they were said. "You" is the person these notes are for; write "you" for them.
        - The summary is three to five short sentences: what the meeting was about and what came of it.
        - A decision is something the people agreed on. Leave the list empty if nothing was decided.
        - An action item is a task someone said they or someone else would do. Give the owner and the due date only
          when they were said; otherwise leave them empty. Never guess. A company's or presenter's own plans, told to
          an audience ("we will ship the new pods early next year"), are not action items: they go in the summary.
        - If "You" mostly listened (a talk, a webcast, an earnings call, a lecture) and did not speak with the people on
          the call, write the notes about what was said on the call. Leave out your side remarks unless they are about
          what was said.
        - Open questions are things raised and left unanswered.
        - Short, clear sentences. No filler, no "the speaker said", no timestamps.
        """

    public static func isAvailable(_ model: Model) -> Bool {
        if model == .claude { return ClaudeCode.isInstalled || ClaudeKey.isSet }
        #if canImport(FoundationModels)
        switch model {
        case .claude: break
        case .onDevice:
            if #available(macOS 26.0, *) { if case .available = SystemLanguageModel.default.availability { return true } }
        case .privateCloud:
            // Needs Apple's private-cloud-compute entitlement (Larynx doesn't have it) and the macOS 27 SDK (CI's macOS
            // 26 machines don't have it), so it is left out; notes come from Claude (docs/dev/MEETING.md).
            break
        }
        #endif
        return false
    }

    /// Rough tokens for English text (about 3.6 characters a token), kept on the safe side.
    static func tokens(_ text: String) -> Int { text.count * 10 / 33 + 1 }

    /// How the transcript's speaker labels read, said once in every prompt.
    static let legend = """
        In the transcript, "You" is the person these notes are for. "On the call" (or "Person 1", "Person 2"...) are the
        other people; work out their names from how they are addressed ("Go ahead, Dana" means the next person to speak
        is Dana) and use the names.
        """

    /// A line for the notes model when "You" said little (under a quarter of the words in a meeting of 150 words or
    /// more): the share, so it can tell a talk you listened to from a meeting you took part in. Nil otherwise.
    static func listeningNote(_ meeting: Meeting) -> String? {
        func count(_ t: String) -> Int { t.split { !($0.isLetter || $0.isNumber) }.count }
        let total = meeting.segments.reduce(0) { $0 + count($1.text) }
        let mine = meeting.segments.filter { $0.speaker == "You" }.reduce(0) { $0 + count($1.text) }
        guard total >= 150, Double(mine) < 0.25 * Double(total) else { return nil }
        return "You said \(Int((100 * Double(mine) / Double(total)).rounded()))% of the words in this meeting."
    }

    /// Claude Code on the person's own plan first; the API key if Claude Code isn't there or fails and a key is saved.
    static func writeWithClaude(_ meeting: Meeting) async throws -> GeneratedNotes {
        guard ClaudeCode.isInstalled else { return try await ClaudeNotes.write(meeting) }
        do { return try await ClaudeCode.write(meeting) }
        catch {
            guard ClaudeKey.isSet else { throw error }
            return try await ClaudeNotes.write(meeting)
        }
    }

    public static func summarize(_ original: Meeting, model: Model) async throws -> MeetingNotes {
        let meeting = original.namingTheCall()
        let transcript = meeting.transcriptText
        guard transcript.rangeOfCharacter(from: .letters) != nil else { throw Failure.empty }
        if model == .claude {
            let started = Date()
            do {
                let notes = verify(try await writeWithClaude(meeting), against: meeting)
                return MeetingNotes(notes, model: model, seconds: Date().timeIntervalSince(started))
            } catch {
                // Claude couldn't (a plan's 5-hour limit, no internet, a bad key): the Mac's own model writes the notes
                // rather than none. The meeting page says so and offers Write the notes again.
                guard isAvailable(.onDevice) else { throw error }
                return try await summarize(original, model: .onDevice)
            }
        }
        guard isAvailable(model) else { throw Failure.unavailable(model == .onDevice ? "Apple Intelligence is off or not supported on this Mac" : "Private Cloud Compute needs macOS 27 and Apple Intelligence") }
        let started = Date()
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            // The small model does best with one narrow job at a time: four short passes over the same transcript
            // (summary, decisions, to-dos, open questions), each with its own small shape. A long meeting is done part by
            // part and the parts joined.
            let budget = model == .onDevice ? 5_000 : 26_000
            let parts = tokens(transcript) <= budget ? [meeting.segments] : split(meeting.segments, budget: budget)
            let named = meeting.addressedNames
            var summaries: [(title: String, summary: [String])] = []
            var decisions: [String] = [], actions: [GeneratedNotes.Item] = [], open: [String] = []
            for part in parts {
                let text = part.map { "[\(Meeting.clock($0.start))] \($0.speaker): \($0.text)" }.joined(separator: "\n")
                let head = parts.count > 1 ? "This is one part of a longer meeting.\n" : ""
                summaries.append(try await summaryPass(head + text, model: model, names: named))
                decisions += try await listPass(head + text, model: model, names: named, name: "decisions", ask: """
                    List every decision made in this meeting. A decision is a choice or an approval: someone in charge
                    says "let's go with...", "let's stay with...", "fine", "do it", or the group agrees. For example, "Let's
                    go with the cheaper venue" is the decision "Chose the cheaper venue", and "Fine, I'll sign off on the
                    $3,000" is "Approved the $3,000". Include the amount or date with its unit when one was said. One
                    decision per item, as a short sentence. If nothing was decided, return an empty list.
                    """)
                actions += try await actionPass(head + text, model: model, names: named)
                open += try await listPass(head + text, model: model, names: named, name: "openQuestions", ask: """
                    List the questions or matters that were raised but left undecided or unknown at the end of the meeting
                    (someone said they don't know yet, it will be decided later, or they will find out). One per item, as a
                    short sentence. If there are none, return an empty list.
                    """)
            }
            var title = summaries.first?.title ?? "Meeting"
            var summary = summaries.flatMap(\.summary)
            if summaries.count > 1 {
                let joined = try await summaryPass("Notes from each part of one meeting, in order:\n" + summaries.map { $0.summary.joined(separator: " ") }.joined(separator: "\n"), model: model)
                title = joined.title; summary = joined.summary
            }
            let notes = verify(GeneratedNotes(title: title, summary: summary, decisions: decisions, actionItems: actions, openQuestions: open),
                               against: meeting)
            return MeetingNotes(notes, model: model, seconds: Date().timeIntervalSince(started))
        }
        #endif
        throw Failure.unavailable("Foundation Models are not on this Mac")
    }

    /// Checks the notes against the transcript before anyone sees them: an owner who isn't named in the meeting is
    /// dropped (the task stays), and an item with a number nobody said is left out. A wrong name or figure in front of
    /// the reader is worse than a missing one.
    static func verify(_ notes: GeneratedNotes, against meeting: Meeting) -> GeneratedNotes {
        let said = meeting.segments.map(\.text).joined(separator: " ").lowercased()
        let saidNumbers = numbers(said)
        func honest(_ text: String) -> Bool { numbers(text.lowercased()).isSubset(of: saidNumbers) }
        var n = notes
        n.summary = n.summary.filter(honest)
        n.decisions = dedupe(n.decisions.filter(honest))
        n.openQuestions = dedupe(n.openQuestions.filter(honest))
        var seen = Set<String>()
        n.actionItems = n.actionItems.filter { honest($0.task) && seen.insert($0.task.lowercased()).inserted }.map { item in
            var it = item
            let owner = it.owner.trimmingCharacters(in: .whitespaces)
            let known = owner.lowercased() == "you" || (owner.count > 1 && said.contains(owner.lowercased()))
            if !known || ["on the call", "person"].contains(where: { owner.lowercased().hasPrefix($0) }) { it.owner = "" }
            if !it.due.isEmpty, !said.contains(it.due.lowercased()) { it.due = "" }
            return it
        }
        return n
    }

    static func numbers(_ text: String) -> Set<String> {
        let ns = text as NSString
        guard let re = try? NSRegularExpression(pattern: "\\d[\\d,]*(?:\\.\\d+)?") else { return [] }
        return Set(re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).replacingOccurrences(of: ",", with: "")
        }.filter { $0.count > 1 })  // single digits ("3 things") are too common to judge
    }

    static func dedupe(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Splits segments into runs that each fit the budget, never mid-utterance.
    static func split(_ segments: [MeetingSegment], budget: Int) -> [[MeetingSegment]] {
        var parts: [[MeetingSegment]] = [[]]
        var used = 0
        for s in segments {
            let t = tokens(s.text) + 8
            if used + t > budget, !parts[parts.count - 1].isEmpty { parts.append([]); used = 0 }
            parts[parts.count - 1].append(s); used += t
        }
        return parts
    }

    #if canImport(FoundationModels)
    // The shapes are described in code rather than with the @Generable macro: the macro's plugin ships with Xcode, not
    // with the command-line tools the installer builds with.

    @available(macOS 26.0, *)
    static func session(_ model: Model, names: [String] = []) throws -> LanguageModelSession {
        let rules = instructions + "\n" + legend + (names.isEmpty ? "" : "\nPeople named in this meeting: " + names.joined(separator: ", ") + ".")
        switch model {
        case .onDevice:
            // Summarizing the user's own meeting is a content transformation, as in Cleaner.
            return LanguageModelSession(model: SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations),
                                        instructions: rules)
        case .privateCloud:
            throw Failure.unavailable("Apple's Private Cloud Compute needs an entitlement Larynx doesn't have")
        case .claude:
            throw Failure.unavailable("Claude is not an Apple model")
        }
    }

    @available(macOS 26.0, *)
    static func summaryPass(_ transcript: String, model: Model, names: [String] = []) async throws -> (title: String, summary: [String]) {
        let text = DynamicGenerationSchema(type: String.self)
        let root = DynamicGenerationSchema(name: "Summary", properties: [
            .init(name: "title", description: "A short title for the meeting, at most eight words", schema: text),
            .init(name: "summary", description: "Three to five short sentences", schema: DynamicGenerationSchema(arrayOf: text, minimumElements: 1, maximumElements: 6)),
        ])
        let reply = try await session(model, names: names).respond(to: """
            Write a title and a summary of this meeting: three to five short sentences on what it was about and what came
            of it. Include the key amounts and dates that were said, each with its unit and meaning exactly as said
            ("$16,000 for 20,000 copies", never a dollar amount as a count).

            Transcript:
            \(transcript)
            """, schema: try GenerationSchema(root: root, dependencies: []), options: GenerationOptions(sampling: .greedy))
        return (try reply.content.value(String.self, forProperty: "title"), try reply.content.value([String].self, forProperty: "summary"))
    }

    @available(macOS 26.0, *)
    static func listPass(_ transcript: String, model: Model, names: [String] = [], name: String, ask: String) async throws -> [String] {
        let root = DynamicGenerationSchema(name: name, properties: [
            .init(name: "items", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self))),
        ])
        let reply = try await session(model, names: names).respond(to: "\(ask)\n\nTranscript:\n\(transcript)",
                                                     schema: try GenerationSchema(root: root, dependencies: []), options: GenerationOptions(sampling: .greedy))
        return try reply.content.value([String].self, forProperty: "items").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    @available(macOS 26.0, *)
    static func actionPass(_ transcript: String, model: Model, names: [String] = []) async throws -> [GeneratedNotes.Item] {
        let text = DynamicGenerationSchema(type: String.self)
        let item = DynamicGenerationSchema(name: "ToDo", properties: [
            .init(name: "task", description: "What will be done, as a short instruction", schema: text),
            .init(name: "owner", description: "Who will do it: a name from the meeting, or 'you'; empty if not clear", schema: text),
            .init(name: "due", description: "When, only if it was said; otherwise empty", schema: text),
        ])
        let root = DynamicGenerationSchema(name: "ToDos", properties: [
            .init(name: "items", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(referenceTo: "ToDo"))),
        ])
        let reply = try await session(model, names: names).respond(to: """
            List every task someone in this meeting said would be done: "I'll...", "I will...", "send me...", or a request
            that was agreed to. For each, the owner is the person who will do it: their name if it was said or clear from who
            was being spoken to, or "you" for the person these notes are for. The due date only if it was said.

            Transcript:
            \(transcript)
            """, schema: try GenerationSchema(root: root, dependencies: [item]), options: GenerationOptions(sampling: .greedy))
        return try reply.content.value([GeneratedContent].self, forProperty: "items").map {
            GeneratedNotes.Item(task: try $0.value(String.self, forProperty: "task"),
                                owner: (try? $0.value(String.self, forProperty: "owner")) ?? "",
                                due: (try? $0.value(String.self, forProperty: "due")) ?? "")
        }
    }
    #endif
}

extension MeetingNotes {
    init(_ notes: GeneratedNotes, model: MeetingSummarizer.Model, seconds: Double) {
        self.init(title: notes.title, summary: notes.summary, decisions: notes.decisions,
                  actionItems: notes.actionItems.map { MeetingActionItem(task: $0.task, owner: $0.owner.nilIfBlank, due: $0.due.nilIfBlank) },
                  openQuestions: notes.openQuestions, model: model.rawValue, seconds: seconds)
    }
}

struct GeneratedNotes {
    struct Item { var task: String; var owner: String; var due: String }
    var title: String
    var summary: [String]
    var decisions: [String]
    var actionItems: [Item]
    var openQuestions: [String]

    var asText: String {
        var lines = ["Title: \(title)", "Summary:"] + summary.map { "- \($0)" }
        lines += ["Decisions:"] + decisions.map { "- \($0)" }
        lines += ["Action items:"] + actionItems.map { "- \($0.task)" + ($0.owner.isEmpty ? "" : " (owner: \($0.owner))") + ($0.due.isEmpty ? "" : " (due: \($0.due))") }
        lines += ["Open questions:"] + openQuestions.map { "- \($0)" }
        return lines.joined(separator: "\n")
    }
}

extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || ["none", "n/a", "unknown", "not specified", "unspecified"].contains(t.lowercased()) ? nil : t
    }
}
