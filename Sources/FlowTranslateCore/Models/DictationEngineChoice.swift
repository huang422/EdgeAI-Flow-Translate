import Foundation

/// Which recognizer the **dictation** flows use — ⌃⌥Space and the Prompt tab.
///
/// Captions are deliberately not part of this choice. Speaker diarization
/// (pyannote + WeSpeaker) runs inside the Nemotron pipeline and Apple's
/// `DictationTranscriber` has no equivalent, so offering the system recognizer
/// for meetings would silently delete the speaker names from the captions, the
/// transcript, the summary and every export. Dictation already runs with
/// diarization off, so there it costs nothing.
///
/// Everything downstream of recognition is identical either way: the same script
/// normalization, the same `SpokenNoiseCleaner`, the same whole-passage Qwen
/// repair through `TranscriptTidier`, the same gates, the same insertion at the
/// cursor. This picks who produces the words, and nothing else.
public enum DictationEngineChoice: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Follow the system: the built-in recognizer where it exists, Nemotron
    /// otherwise. The default.
    case automatic
    /// Apple's on-device `DictationTranscriber`. macOS 26+ only.
    case appleSpeech
    /// The bundled NVIDIA Nemotron streaming model. Available everywhere.
    case nemotron

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: return "自動 Automatic"
        case .appleSpeech: return "Mac 內建 Built-in"
        case .nemotron: return "Nemotron"
        }
    }

    /// What this choice resolves to when the built-in recognizer is / is not
    /// available on the running system.
    ///
    /// Kept here, next to the enum, so the rule has one home: below macOS 26
    /// there is no `DictationTranscriber` at all, so **every** choice resolves to
    /// Nemotron — including an `appleSpeech` value persisted on a newer machine
    /// and carried to an older one by a synced settings file.
    public func resolved(builtInAvailable: Bool) -> ResolvedDictationEngine {
        guard builtInAvailable else { return .nemotron }
        switch self {
        case .automatic, .appleSpeech: return .appleSpeech
        case .nemotron: return .nemotron
        }
    }
}

/// The engine actually in use, after `DictationEngineChoice` has been resolved
/// against the running system.
public enum ResolvedDictationEngine: String, Sendable, Equatable {
    case appleSpeech
    case nemotron
}
