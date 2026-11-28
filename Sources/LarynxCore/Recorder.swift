import AVFoundation
import LarynxObjC

/// Captures the default microphone and keeps 16 kHz mono Float32 samples, the format Parakeet expects.
public final class Recorder: @unchecked Sendable {
    public static let sampleRate: Double = 16_000

    private var engine = AVAudioEngine()
    /// The audio hardware changed under the engine (a USB microphone or webcam reconnected, the default input
    /// switched). A stale engine can raise an exception when the microphone is opened, so the next start uses a
    /// fresh one.
    private var stale = false
    private var changeObserver: NSObjectProtocol?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Recorder.sampleRate, channels: 1, interleaved: false)!

    public private(set) var isRecording = false
    private var lastLevel: Float = 0
    /// How long the microphone stays open after a dictation (seconds; 0 closes it at once). A warm microphone starts
    /// instantly and includes `preRoll` from just before the press; a cold one takes 150-300 ms, enough to lose the
    /// first syllable. While warm, audio only passes through a `preRoll`-long ring in memory and is never kept.
    public var warmSeconds: () -> Double = { 0 }
    /// The microphone to use (a CoreAudio device UID, `micDevice`); empty or unplugged means the system default.
    public var deviceUID: () -> String = { "" }
    private var activeUID = ""
    public static let preRoll: Double = 0.15
    private var ring: [Float] = []
    private var cooling: DispatchWorkItem?
    /// True while `stopAfterTail` is still listening past key-up; a `start()` then takes over instead.
    private var tailing = false
    private var handedOver: [Float]?
    /// True from key-up until that recording is collected (`willStop()`): a press in between starts its own.
    private var stopPending = false

    /// Loudness of the most recent buffer (RMS, 0...1; speech is usually 0.01-0.3). Drives the pill's waveform.
    public var level: Float {
        lock.lock(); defer { lock.unlock() }
        return isRecording ? lastLevel : 0
    }

    public init() { watch() }

    private func watch() {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.lock.withLock { self?.stale = true }
        }
    }

    /// A new engine in place of one the hardware changed under.
    private func freshEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        lock.withLock { stale = false }
        watch()
    }

    public func start() throws {
        if isRecording {
            // A new press while the last dictation's tail is still recording: hand that recording over and keep the
            // microphone running for the new one.
            // The same when the key was let go but that recording hasn't been collected yet: without this, the new press
            // had no recording of its own and its release got the previous one again (pasted twice, Nov 12).
            lock.lock(); defer { lock.unlock() }
            if tailing || stopPending {
                handedOver = samples; samples.removeAll(keepingCapacity: true); tailing = false; stopPending = false
            }
            return
        }
        cooling?.cancel(); cooling = nil
        // A different microphone was picked while the engine stayed warm: start over on the new one.
        if engine.isRunning, deviceUID() != activeUID { coolDownNow() }
        if engine.isRunning {
            // Still warm from the last dictation: start at once, with the moment just before the press.
            lock.withLock { samples = ring; ring.removeAll(keepingCapacity: true); isRecording = true }
            return
        }
        lock.lock(); samples.removeAll(keepingCapacity: true); ring.removeAll(); lock.unlock()
        if lock.withLock({ stale }) { freshEngine() }
        do {
            try open()
        } catch {
            // Once more on a fresh engine before giving up: that clears a microphone whose format changed.
            lastStartProblem = "\(error.localizedDescription); retried on a fresh audio engine"
            freshEngine()
            try open()
        }
        lock.withLock { isRecording = true }
    }

    /// What went wrong the last time the microphone needed a second try (for the log), or nil.
    public var lastStartProblem: String?

    private func open() throws {
        let input = engine.inputNode
        // Point the input at the chosen microphone before reading its format (system default if it's gone).
        let uid = deviceUID()
        if !uid.isEmpty, var device = AudioDevices.id(forUID: uid), let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        activeUID = uid
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw LarynxError.noMicrophone }
        guard format.channelCount > 0 else { throw LarynxError.noMicrophone }
        converter = AVAudioConverter(from: format, to: target)
        var started: Error?
        let raised = LarynxCatch {
            input.removeTap(onBus: 0)  // a warm engine the system stopped (device change) may still hold the old tap
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.append(buffer)
            }
            engine.prepare()
            do { try engine.start() } catch { started = error }
        }
        if let raised { throw raised }
        if let started { throw started }
    }

    /// The key was let go: the recording will be collected shortly (by `stopAfterTail`). A press before that starts
    /// a recording of its own.
    public func willStop() { lock.withLock { stopPending = true } }

    /// Stops capture and returns everything recorded since `start()`, once: a second call returns nothing.
    @discardableResult
    public func stop() -> [Float] {
        if isRecording {
            lock.withLock { isRecording = false }
            let warm = warmSeconds()
            if warm > 0 {
                let work = DispatchWorkItem { [weak self] in self?.coolDown() }
                cooling = work
                DispatchQueue.main.asyncAfter(deadline: .now() + warm, execute: work)
            } else {
                coolDown()
            }
        }
        lock.lock(); defer { lock.unlock() }
        stopPending = false
        let out = samples
        samples.removeAll(keepingCapacity: true)
        return out
    }

    private func coolDownNow() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock { ring.removeAll() }
    }

    /// Closes the microphone now (unless a dictation started meanwhile).
    public func coolDown() {
        guard !isRecording, engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock { ring.removeAll() }
    }

    /// Stops at key-up, unless the last word is still being spoken: then keeps recording until it goes quiet, for at
    /// most `maxTail` seconds, so the end of a word said as the key comes up isn't cut off. Most dictations end in a
    /// pause and stop at once, so this adds no delay to them. Returns the samples and how long the tail ran.
    public func stopAfterTail(maxTail: TimeInterval = 0.3) async -> (samples: [Float], tailMs: Int) {
        // A new press already set this recording aside and is recording on: hand it over without stopping.
        if let taken: [Float] = lock.withLock({ defer { handedOver = nil }; return handedOver }) { return (taken, 0) }
        guard isRecording, maxTail > 0, Recorder.speechAtEnd(snapshot()) else { return (stop(), 0) }
        lock.withLock { tailing = true }
        let started = Date()
        while Date().timeIntervalSince(started) < maxTail {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if !lock.withLock({ tailing }) { break }
            if !Recorder.speechAtEnd(snapshot()) { break }
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        // A new press took over during the tail: it already set this recording aside.
        let taken: [Float]? = lock.withLock {
            defer { handedOver = nil; tailing = false }
            return handedOver
        }
        if let taken { return (taken, ms) }
        return (stop(), ms)
    }

    /// Is someone still talking at the end of `samples`? The last 100 ms is well above the clip's own noise floor.
    public static func speechAtEnd(_ samples: [Float]) -> Bool {
        let frame = Int(sampleRate * 0.05)
        guard samples.count >= frame * 4 else { return false }
        var frames: [Float] = []
        var i = max(0, samples.count - Int(sampleRate * 10))  // the last 10 s is plenty for the noise floor
        while i + frame <= samples.count { frames.append(rms(Array(samples[i..<(i + frame)]))); i += frame }
        let floor = frames.sorted()[frames.count / 10]
        let end = rms(Array(samples.suffix(frame * 2)))
        return end > max(0.012, floor * 4)
    }

    /// Tests only: recording without a microphone, and samples arriving as if from one.
    func beginForTest() { lock.withLock { isRecording = true } }
    func appendForTest(_ more: [Float]) { lock.withLock { samples.append(contentsOf: more) } }

    /// Everything recorded so far, without stopping (for the live preview).
    public func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    /// Root-mean-square loudness. Room noise sits around 0.001-0.005; speech is usually above 0.01.
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for x in samples { sum += x * x }
        return (sum / Float(samples.count)).squareRoot()
    }

    public var seconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / Recorder.sampleRate
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData else { return }
        let chunk = UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength))
        var sum: Float = 0
        for x in chunk { sum += x * x }
        let rms = chunk.isEmpty ? 0 : (sum / Float(chunk.count)).squareRoot()
        lock.lock()
        if isRecording {
            samples.append(contentsOf: chunk)
        } else {
            // Warm but not recording: keep only the last `preRoll` seconds, to put in front of the next press.
            ring.append(contentsOf: chunk)
            let keep = Int(Recorder.sampleRate * Recorder.preRoll)
            if ring.count > keep { ring.removeFirst(ring.count - keep) }
        }
        lastLevel = rms
        lock.unlock()
    }
}

/// Reads any audio file macOS can decode and returns 16 kHz mono samples.
public func loadAudioFile(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Recorder.sampleRate, channels: 1, interleaved: false)!
    guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
    else { throw LarynxError.unreadableAudio }
    // One read can return only part of the file (float WAVs come back in pieces), so read until the end.
    while file.framePosition < file.length {
        guard let piece = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length - file.framePosition))
        else { throw LarynxError.unreadableAudio }
        try file.read(into: piece)
        guard piece.frameLength > 0 else { break }
        guard let src = piece.floatChannelData, let dst = input.floatChannelData else { throw LarynxError.unreadableAudio }
        for ch in 0..<Int(file.processingFormat.channelCount) {
            (dst[ch] + Int(input.frameLength)).update(from: src[ch], count: Int(piece.frameLength))
        }
        input.frameLength += piece.frameLength
    }
    // Already 16 kHz mono (the crash spool, most test fixtures): copy, so not a single sample is lost.
    if file.processingFormat.sampleRate == target.sampleRate, file.processingFormat.channelCount == 1,
       let channel = input.floatChannelData {
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(input.frameLength)))
    }
    guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else { throw LarynxError.unreadableAudio }
    // The converter holds back its last few milliseconds until it is told the stream ended, so keep pulling until it does.
    let chunk = AVAudioFrameCount(target.sampleRate)
    var samples: [Float] = []
    samples.reserveCapacity(Int(Double(input.frameLength) * target.sampleRate / file.processingFormat.sampleRate) + 64)
    var fed = false
    while true {
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: chunk) else { throw LarynxError.unreadableAudio }
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .endOfStream; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return input
        }
        if let error { throw error }
        if let channel = out.floatChannelData, out.frameLength > 0 {
            samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
        }
        if status == .endOfStream || status == .error || (status == .inputRanDry && out.frameLength == 0) { break }
    }
    return samples
}
