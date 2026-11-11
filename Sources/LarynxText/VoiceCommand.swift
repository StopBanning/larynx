import Foundation

/// Whole dictations that are commands rather than words to type.
public enum VoiceCommand {
    /// "Scratch that", "undo that", "delete that" said on their own (any capitals, end punctuation).
    public static func isUndo(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        return ["scratch that", "undo that", "delete that"].contains(t)
    }
}
