import Foundation

/// Where the speech model is on its way to being usable, for the setup window (PLAN-launch L0.7): every wait a new
/// user sits through gets a bar, plain words and a time. FluidAudio reports no download progress, so the fraction is
/// the model folder's size on disk against the size it ends up at.
public enum ModelSetup {
    public enum State: Equatable, Sendable {
        /// `secondsLeft` is nil until the speed is known.
        case downloading(fraction: Double, megabytes: Int, of: Int, secondsLeft: Int?)
        /// On disk; macOS is compiling it for the Neural Engine (once per install, usually one to three minutes).
        case preparing
        case ready
    }

    /// The model folder's size once everything is downloaded (measured Nov 2026; a few percent off is fine).
    public static func expectedBytes(_ engine: Engine) -> Int64 {
        let megabytes: Int64
        switch engine {
        case .ultra: megabytes = 603
        case .unified: megabytes = 586
        case .parakeet: megabytes = 461
        case .clean: megabytes = 427
        case .bark3: megabytes = 416
        }
        return megabytes * 1_048_576
    }

    /// Bytes under `folder`, counting files still being written. 0 when it doesn't exist yet.
    public static func folderBytes(_ folder: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// `bytesPerSecond`: the recent download speed, nil or 0 when unknown.
    public static func state(loaded: Bool, bytes: Int64, expected: Int64, bytesPerSecond: Double?) -> State {
        if loaded { return .ready }
        // The last few percent are small files and rounding: past 97% the download is over and the compile has begun.
        guard expected > 0, Double(bytes) < 0.97 * Double(expected) else { return .preparing }
        let left = (bytesPerSecond ?? 0) > 1 ? Int((Double(expected - bytes) / bytesPerSecond!).rounded(.up)) : nil
        return .downloading(fraction: Double(bytes) / Double(expected), megabytes: Int(bytes / 1_048_576), of: Int(expected / 1_048_576), secondsLeft: left)
    }

    /// "about 40 s", "about 3 min": rounded the way a person would say it.
    public static func timeLeft(_ seconds: Int) -> String {
        if seconds < 50 { return "about \(max(10, (seconds + 9) / 10 * 10)) s" }
        return "about \(Int((Double(seconds) / 60).rounded(.up))) min"
    }
}
