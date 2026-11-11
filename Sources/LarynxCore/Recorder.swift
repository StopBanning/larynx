import AVFoundation

/// Captures the default microphone and keeps 16 kHz mono Float32 samples, the format Parakeet expects.
public final class Recorder: @unchecked Sendable {
    public static let sampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Recorder.sampleRate, channels: 1, interleaved: false)!

    public private(set) var isRecording = false
    private var lastLevel: Float = 0

    /// Loudness of the most recent buffer (RMS, 0...1; speech is usually 0.01-0.3). Drives the pill's waveform.
    public var level: Float {
        lock.lock(); defer { lock.unlock() }
        return isRecording ? lastLevel : 0
    }

    public init() {}

    public func start() throws {
        guard !isRecording else { return }
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw LarynxError.noMicrophone }
        converter = AVAudioConverter(from: format, to: target)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops capture and returns everything recorded since `start()`.
    @discardableResult
    public func stop() -> [Float] {
        if isRecording {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRecording = false
        }
        lock.lock(); defer { lock.unlock() }
        return samples
    }

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
        lock.lock(); samples.append(contentsOf: chunk); lastLevel = rms; lock.unlock()
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
