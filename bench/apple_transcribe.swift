// Apple's on-device SpeechTranscriber (macOS 26) on audio files, for bench/compare.py. It downloads nothing and asks
// for no permission: if the English model is not already on the Mac, each file reports an error instead.
// Build: swiftc -parse-as-library -O bench/apple_transcribe.swift -o <out>; run: <out> a.wav b.wav ...
// Prints one line per file: the path, a tab, the transcript.
import AVFoundation
import Foundation
import Speech

@main struct AppleTranscribe {
    static func main() async {
        for path in CommandLine.arguments.dropFirst() {
            do {
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
                let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .transcription)
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                async let text: String = {
                    var s = ""
                    for try await r in transcriber.results where r.isFinal { s += String(r.text.characters) }
                    return s
                }()
                if let last = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                print(path + "\t" + (try await text).trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                print(path + "\tERROR: \(error)")
            }
        }
    }
}
