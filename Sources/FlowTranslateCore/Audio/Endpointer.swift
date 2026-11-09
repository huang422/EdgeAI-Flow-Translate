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
    /// Each deferral waits for `semanticGrace` more audio seconds.
    public var maxGraceEndings: Int
    public var semanticGrace: TimeInterval
    public var extendUnpunctuatedSpeech: Bool

    public init(minSpeech: TimeInterval = 0.30, maxSpeech: TimeInterval = 8,
                maxGraceEndings: Int = 1, semanticGrace: TimeInterval = 0.8,
                extendUnpunctuatedSpeech: Bool = false) {
        self.minSpeech = minSpeech
        self.maxSpeech = maxSpeech
        self.maxGraceEndings = max(0, maxGraceEndings)
        self.semanticGrace = max(0, semanticGrace)
        self.extendUnpunctuatedSpeech = extendUnpunctuatedSpeech
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
/// and gives an unfinished thought a bounded extension of the same silence.
public struct Endpointer {
    public private(set) var config: EndpointerConfig
    public private(set) var inUtterance = false

    private var elapsed: TimeInterval = 0   // total time since onset
    private var graceUsed = 0
    private var graceRemaining: TimeInterval?

    public init(config: EndpointerConfig = .default) { self.config = config }

    public mutating func reset() {
        inUtterance = false
        elapsed = 0
        graceUsed = 0
        graceRemaining = nil
    }

    public static let minContentToClose = 2

    /// Whether `text` is long enough to be a sentence of its own.
    ///
    /// Script-aware, because the unit differs: two Latin characters is "OK" — a
    /// complete answer — while two Chinese characters is "然後" or "好的", which is
    /// a speaker thinking out loud. Counting characters alone made the same
    /// number mean two very different amounts of speech, and the visible result
    /// was caption lines two characters long.
    ///
    /// This does not veto a close, it defers one: a genuine short reply still
    /// lands one silence window later, through the same grace budget that holds
    /// an unfinished thought open.
    public static func isSentenceLength(_ text: String) -> Bool {
        let content = TextCounting.contentCharacters(text)
        guard content > 0 else { return false }
        return TokenEstimator.isCJKDominant(text) ? content >= minCJKSentence : content >= minContentToClose
    }

    /// Four Chinese characters — "我知道了", "沒問題了". Below that is a filler or a
    /// backchannel far more often than it is a sentence.
    public static let minCJKSentence = 4

    /// Give a short decoded reply time to continue. Silence or noise with no
    /// decoded text should never consume the grace period.
    public static func isTooShortToClose(_ text: String) -> Bool {
        guard TextCounting.contentCharacters(text) > 0 else { return false }
        return !isSentenceLength(text)
    }
    /// Provisional text can defer an acoustic close, but never ends active
    /// speech on its own. Silero sends one end event per pause, so the grace
    /// counts down in audio time and expires even if the speaker stays quiet.
    public mutating func process(
        speechStarted: Bool, speechEnded: Bool, partial: String = "", dt: TimeInterval
    ) -> [EndpointEvent] {
        var events: [EndpointEvent] = []
        if speechStarted {
            if !inUtterance {
                inUtterance = true
                events.append(.start)
            }
            graceRemaining = nil
        }
        guard inUtterance else { return events }
        elapsed += dt

        if speechEnded, elapsed < config.minSpeech,
           TextCounting.contentCharacters(partial) == 0 {
            reset()
            return events
        }

        if elapsed >= config.maxSpeech {
            events.append(.finalize)
            reset()
        } else if speechEnded {
            let lastWordOrPunctuation = partial.last {
                !$0.isWhitespace && !"」』）】》\u{201D}\u{2019}\"')]}".contains($0)
            }
            let unpunctuated = config.extendUnpunctuatedSpeech
                && lastWordOrPunctuation.map { !".?!。！？".contains($0) } == true
            let needsGrace = unpunctuated || SemanticEndpoint.isIncomplete(partial)
                || Self.isTooShortToClose(partial)
            if needsGrace, graceUsed < config.maxGraceEndings, config.semanticGrace > 0 {
                graceUsed += 1
                graceRemaining = config.semanticGrace
            } else {
                events.append(.finalize)
                reset()
            }
        } else if let remaining = graceRemaining {
            if dt >= remaining {
                events.append(.finalize)
                reset()
            } else {
                graceRemaining = remaining - dt
            }
        }
        return events
    }
}
