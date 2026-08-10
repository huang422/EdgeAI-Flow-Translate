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
    ///
    /// Punctuation alone is not enough. A streaming recognizer punctuates the
    /// partial it has *so far*, so a speaker 300 ms into "好，我們開始討論" emits
    /// a partial of "好。" — terminal punctuation on one character — and this
    /// trigger would close the utterance there, leaving a caption line of a
    /// single character and the rest of the sentence starting a new one. Worst on
    /// Chinese, where one character is a whole word and the recognizer is most
    /// willing to punctuate early.
    ///
    /// So an early close also needs enough content to be a sentence. Counted in
    /// letters, digits and CJK characters rather than words, because a Chinese
    /// line has no spaces to count.
    public static func endsSentence(_ s: String) -> Bool {
        guard let last = s.last, ".?!。！？…".contains(last) else { return false }
        return TextCounting.contentCharacters(s) >= minContentToClose
    }

    /// Below this, terminal punctuation is treated as mid-utterance noise and the
    /// acoustic endpoint is left to decide.
    ///
    /// Two, not more: "Yes." and "OK." are complete answers and should still
    /// close early, while "好。" and "嗯。" are the fragments this exists to stop.
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

    /// Whether the live text is too short to close on — the `tooShort` argument
    /// to `process`.
    ///
    /// **Empty is not short.** `isSentenceLength("")` is correctly `false` (an
    /// empty string is not a sentence), but the call site inverted it into
    /// "too short to close", which is a different claim: with no partial at all
    /// there is nothing to judge. A cough or a keyboard click that outlasts
    /// `minSpeech` before the recognizer emits anything therefore burned the
    /// utterance's only semantic deferral, and `graceUsed` only resets at the
    /// next `.start` — which does not fire, because the blip already opened the
    /// utterance. Real speech then began inside it with no grace left and got cut
    /// mid-thought at the first pause: the exact failure the semantic endpointer
    /// exists to prevent, triggered by silence.
    public static func isTooShortToClose(_ text: String) -> Bool {
        guard TextCounting.contentCharacters(text) > 0 else { return false }
        return !isSentenceLength(text)
    }


    /// Advance by one chunk of `dt` seconds. `speechStarted`/`speechEnded` are the
    /// Silero stream events; `sentenceEnded` is a terminal-punctuation hint (used
    /// only as a secondary close once `minSpeech` is met); `sentenceIncomplete`
    /// is the semantic hint that the live text ends mid-thought — an acoustic
    /// endpoint arriving then is deferred (up to `maxGraceEndings` times).
    /// - Parameter tooShort: the live text is not yet a sentence's worth of
    ///   speech. Treated exactly like `sentenceIncomplete`: it defers one
    ///   acoustic close rather than vetoing it.
    public mutating func process(
        speechStarted: Bool, speechEnded: Bool, sentenceEnded: Bool,
        sentenceIncomplete: Bool = false, speakerChanged: Bool = false,
        tooShort: Bool = false,
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
            // Two reasons to hold the utterance open for one more silence
            // window: it ends mid-thought, or there is not yet enough of it to
            // be a sentence. The second is what produced two-character caption
            // lines — a speaker pausing after "然後" or "好的" hit the acoustic
            // endpoint with a complete-sounding fragment, so the semantic check
            // had nothing to object to.
            if (sentenceIncomplete || tooShort) && graceUsed < config.maxGraceEndings {
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
