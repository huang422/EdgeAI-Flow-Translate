import Foundation

/// Tuning for `Endpointer`. Onset/endpoint detection is fully owned by the Silero
/// VAD state machine; this only drops sub-`minSpeech` blips and force-flushes a
/// non-stop talker at `maxSpeech` (Silero has no max-length cap on its own).
public struct EndpointerConfig: Sendable, Equatable {
    /// Minimum voiced time before an utterance can finalize (drops coughs/clicks).
    public var minSpeech: TimeInterval
    /// Hard cap so a non-stop talker still flushes to ASR/translation.
    public var maxSpeech: TimeInterval
    /// How many acoustic endpoints may be deferred per utterance when the live
    /// text looks unfinished (semantic endpointing, see `SemanticEndpoint`).
    /// Each deferral waits one more VAD silence window; `maxSpeech` still caps.
    public var maxGraceEndings: Int

    public init(minSpeech: TimeInterval = 0.30, maxSpeech: TimeInterval = 8,
                maxGraceEndings: Int = 1) {
        self.minSpeech = minSpeech
        self.maxSpeech = maxSpeech
        self.maxGraceEndings = max(0, maxGraceEndings)
    }

    public static let `default` = EndpointerConfig()
}

/// What an `Endpointer` step decides for the caller.
public enum EndpointEvent: Equatable, Sendable {
    /// Speech just started.
    case start
    /// The current utterance should be finalized now.
    case finalize
}

/// Pure utterance-boundary tracker driven by Silero `speechStart`/`speechEnd`
/// events. Source-agnostic and deterministic so it is fully unit tested without a
/// model. Silero decides starts/endpoints; this enforces a minimum/maximum length
/// and lets terminal punctuation close a sentence early (secondary to the VAD).
public struct Endpointer {
    public private(set) var config: EndpointerConfig
    public private(set) var inUtterance = false

    private var elapsed: TimeInterval = 0   // total time since onset
    private var graceUsed = 0               // semantic-endpoint deferrals so far

    public init(config: EndpointerConfig = .default) { self.config = config }

    public mutating func reset() {
        inUtterance = false
        elapsed = 0
        graceUsed = 0
    }

    /// Whether terminal punctuation ends the live partial, enabling an early close.
    public static func endsSentence(_ s: String) -> Bool {
        guard let last = s.last else { return false }
        return ".?!。！？…".contains(last)
    }

    /// Advance by one chunk of `dt` seconds. `speechStarted`/`speechEnded` are the
    /// Silero stream events; `sentenceEnded` is a terminal-punctuation hint (used
    /// only as a secondary close once `minSpeech` is met); `sentenceIncomplete`
    /// is the semantic hint that the live text ends mid-thought — an acoustic
    /// endpoint arriving then is deferred (up to `maxGraceEndings` times).
    public mutating func process(
        speechStarted: Bool, speechEnded: Bool, sentenceEnded: Bool,
        sentenceIncomplete: Bool = false, speakerChanged: Bool = false,
        dt: TimeInterval
    ) -> [EndpointEvent] {
        var events: [EndpointEvent] = []

        if speechStarted && !inUtterance {
            inUtterance = true
            elapsed = 0
            graceUsed = 0
            events.append(.start)
        }
        guard inUtterance else { return events }

        elapsed += dt

        // Primary: Silero endpoint. Finalize if long enough, else drop the blip.
        if speechEnded {
            if elapsed < config.minSpeech {
                reset()
                return events
            }
            // Semantic grace: the text ends mid-thought ("so", "然後…") — hold
            // the utterance open for one more silence window instead of cutting.
            if sentenceIncomplete && graceUsed < config.maxGraceEndings {
                graceUsed += 1
                return events
            }
            events.append(.finalize)
            reset()
            return events
        }
        // A different speaker took over → close the current line immediately.
        // Then sentence punctuation, then the wall-clock max cap.
        if elapsed >= config.minSpeech && (sentenceEnded || speakerChanged) || elapsed >= config.maxSpeech {
            events.append(.finalize)
            reset()
        }
        return events
    }
}
