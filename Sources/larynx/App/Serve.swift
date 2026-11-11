import AppKit
import AVFoundation
import Foundation
import LarynxCore

/// One JSON object per line in, one per line out. Commands run in order.
func runServe() async {
    let lines = AsyncStream<String> { continuation in
        Thread {
            while let line = readLine() { continuation.yield(line) }
            continuation.finish()
        }.start()
    }
    Task {
        do {
            try await Loader.shared.task.value
            emit(["event": "ready", "model": engine.modelName, "rewriteAvailable": Cleaner.isAvailable,
                  "pasteAllowed": Inserter.isTrusted])
        } catch {
            emit(["event": "error", "message": "model failed to load: \(error)"])
        }
    }
    for await line in lines {
        guard let data = line.data(using: .utf8),
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cmd = request["cmd"] as? String
        else { emit(["event": "error", "message": "expected a JSON object with a cmd"]); continue }
        let id = request["id"]
        func reply(_ body: [String: Any]) {
            var body = body
            if let id { body["id"] = id }
            emit(body)
        }
        switch cmd {
        case "start":
            guard await requestMicrophone() else { reply(["event": "error", "message": "microphone access was refused"]); continue }
            do { try recorder.start(); reply(["event": "recording"]) }
            catch { reply(["event": "error", "message": "\(error)"]) }
        case "stop":
            let samples = recorder.stop()
            reply(["event": "processing", "audioSeconds": Double(samples.count) / Recorder.sampleRate])
            do {
                var result = try await finish(samples, clean: request["clean"] as? Bool ?? false,
                                              mode: (request["mode"] as? String).flatMap(CleanupMode.init(rawValue:)) ?? .standard,
                                              tidy: !(request["verbatim"] as? Bool ?? false))
                if request["paste"] as? Bool == true, !result.text.isEmpty {
                    let text = result.text
                    let delivery = await Inserter.deliver(text)
                    result.delivered = delivery.label
                    result.pasted = { if case .copied = delivery { return false } else { return true } }()
                    if case .copied(let why) = delivery { result.pasteError = why }
                }
                var body = try result.jsonObject()
                body["event"] = "result"
                reply(body)
            } catch { reply(["event": "error", "message": "\(error)"]) }
        case "cancel":
            recorder.stop()
            reply(["event": "cancelled"])
        case "transcribe":
            guard let path = request["path"] as? String else { reply(["event": "error", "message": "transcribe needs a path"]); continue }
            do {
                let result = try await finish(try loadAudioFile(URL(fileURLWithPath: path)), clean: request["clean"] as? Bool ?? false,
                                              mode: (request["mode"] as? String).flatMap(CleanupMode.init(rawValue:)) ?? .standard,
                                              tidy: !(request["verbatim"] as? Bool ?? false))
                var body = try result.jsonObject()
                body["event"] = "result"
                reply(body)
            } catch { reply(["event": "error", "message": "\(error)"]) }
        case "status":
            reply(["event": "status", "loaded": await transcriber.isLoaded, "recording": recorder.isRecording,
                   "rewriteAvailable": Cleaner.isAvailable, "pasteAllowed": Inserter.isTrusted])
        case "quit":
            recorder.stop()
            exit(0)
        default:
            reply(["event": "error", "message": "unknown cmd \(cmd)"])
        }
    }
    exit(0)
}

