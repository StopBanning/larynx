import AVFoundation
import CoreAudio
import Foundation
import LarynxCore

/// The two sides of a meeting as 16 kHz mono audio (docs/MEETINGS.md): the microphone ("You") through its own audio
/// engine, so dictation keeps working during a meeting, and the call's audio through macOS's process tap (macOS 14.4+):
/// no driver, one "System Audio Recording" permission the first time. Both are written to the meeting's spool files as
/// they arrive, so a crash or a closed lid loses nothing.
final class MeetingCapture: @unchecked Sendable {
    typealias Sink = @Sendable (_ samples: [Float], _ side: String) -> Void

    private let mic = AVAudioEngine()
    private var micConverter: AVAudioConverter?
    private var tap: CallAudioTap?
    private let sink: Sink
    private let spool: [String: FileHandle]
    private let lock = NSLock()
    private(set) var levels: [String: Float] = ["You": 0, "On the call": 0]
    private(set) var callAudioError: String?
    /// Muted: the microphone side is written as silence, not skipped, so the two tracks stay the same length and the
    /// transcript's times stay lined up with the call.
    private var micMuted = false
    func setMicMuted(_ muted: Bool) { lock.lock(); micMuted = muted; lock.unlock() }

    static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    init(id: String, sink: @escaping Sink) throws {
        self.sink = sink
        let folder = MeetingStore.folder.appendingPathComponent("spool", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var handles: [String: FileHandle] = [:]
        for (side, file) in [("You", "\(id)-you.f32"), ("On the call", "\(id)-call.f32")] {
            let url = folder.appendingPathComponent(file)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handles[side] = try FileHandle(forWritingTo: url)
        }
        spool = handles
    }

    /// Starts the microphone, then the call's audio. A call-audio failure (permission refused, older macOS) is kept in
    /// `callAudioError` and the meeting goes on with the microphone alone, which still hears an in-person meeting.
    func start() throws {
        let input = mic.inputNode
        let format = input.outputFormat(forBus: 0)
        micConverter = AVAudioConverter(from: format, to: Self.target)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.deliver(buffer, side: "You", converter: self?.micConverter)
        }
        mic.prepare()
        try mic.start()
        if #available(macOS 14.4, *) {
            let t = CallAudioTap()
            do {
                try t.start { [weak self] buffer, converter in self?.deliver(buffer, side: "On the call", converter: converter) }
                tap = t
            } catch {
                callAudioError = "\(error)"
            }
        } else {
            callAudioError = "Hearing the call needs macOS 14.4 or later."
        }
    }

    func stop() {
        mic.inputNode.removeTap(onBus: 0)
        mic.stop()
        if #available(macOS 14.4, *) { (tap as CallAudioTap?)?.stop() }
        tap = nil
        lock.lock(); defer { lock.unlock() }
        for h in spool.values { try? h.synchronize(); try? h.close() }
    }

    private func deliver(_ buffer: AVAudioPCMBuffer, side: String, converter: AVAudioConverter?) {
        guard let converter else { return }
        let ratio = Self.target.sampleRate / buffer.format.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, let data = out.floatChannelData, out.frameLength > 0 else { return }
        var samples = Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
        lock.lock()
        if side == "You" && micMuted { samples = [Float](repeating: 0, count: samples.count) }
        var peak: Float = 0
        for s in samples { peak = max(peak, abs(s)) }
        levels[side] = peak
        let handle = spool[side]
        lock.unlock()
        samples.withUnsafeBufferPointer { try? handle?.write(contentsOf: Data(buffer: $0)) }
        sink(samples, side)
    }

    func level(_ side: String) -> Float { lock.lock(); defer { lock.unlock() }; return levels[side] ?? 0 }
}

/// Everything the Mac plays (the call), through a private process tap and a private aggregate device. Larynx's own
/// sounds are not in it: the tap leaves this process out.
@available(macOS 14.4, *)
final class CallAudioTap: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case status(String, OSStatus)
        var description: String {
            switch self { case .status(let what, let s): return "\(what) failed (\(s)). Allow Larynx in System Settings → Privacy & Security → System Audio Recording." }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "larynx.meeting.call-audio")

    func start(_ deliver: @escaping (AVAudioPCMBuffer, AVAudioConverter?) -> Void) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcessObject()].compactMap { $0 })
        description.uuid = UUID()
        description.name = "Larynx meeting"
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.unmuted
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw Failure.status("Hearing the call", status) }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr, let avFormat = AVAudioFormat(streamDescription: &format) else { throw Failure.status("Reading the call's audio format", status) }
        let converter = AVAudioConverter(from: avFormat, to: MeetingCapture.target)

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Larynx meeting",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID)
        guard status == noErr else { stop(); throw Failure.status("Setting up the call audio", status) }

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, bufferListNoCopy: input, deallocator: nil) else { return }
            deliver(buffer, converter)
        }
        guard status == noErr else { stop(); throw Failure.status("Listening to the call", status) }
        status = AudioDeviceStart(deviceID, procID)
        guard status == noErr else { stop(); throw Failure.status("Starting the call audio", status) }
    }

    func stop() {
        if deviceID != kAudioObjectUnknown {
            if let procID { AudioDeviceStop(deviceID, procID); AudioDeviceDestroyIOProcID(deviceID, procID) }
            AudioHardwareDestroyAggregateDevice(deviceID)
            deviceID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
    }

    /// This process as an audio object, so the tap leaves Larynx's own sounds out.
    private func ownProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}
