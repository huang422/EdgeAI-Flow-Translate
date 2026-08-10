import AVFoundation
import Foundation
import FlowTranslateCore

/// One recognizer, as dictation needs it.
///
/// Two implementations: `NemotronDictationEngine`, which borrows the app's shared
/// streaming service, and `AppleDictationEngine`, which drives macOS 26's
/// `DictationTranscriber`. `DictationSession` owns the parts that are the same
/// either way — the microphone permission, the `AudioRouter` borrow, the
/// warming/listening state machine and the drain window — so an engine only has
/// to answer for turning audio into text.
///
/// Deliberately narrow. Nothing here mentions a tier, a scenario, diarization or
/// a model file: those are Nemotron's vocabulary, and the whole point of the
/// protocol is that the session no longer speaks it.
@MainActor
protocol DictationEngine: AnyObject {
    /// The sentence in progress, revised as it is heard.
    var onInterim: ((String) -> Void)? { get set }
    /// One finished sentence, appended to whatever came before.
    var onFinalized: ((String) -> Void)? { get set }
    /// 0…1 while model assets are being fetched, if this engine fetches any.
    var onDownloadProgress: ((Double) -> Void)? { get set }

    /// Whether this engine's finalized segments already carry the spacing that
    /// belongs between them.
    ///
    /// The two engines segment very differently and the caller cannot join them
    /// the same way. Apple's `DictationTranscriber` finalizes *progressively*,
    /// several segments to a sentence, and each result's text arrives with the
    /// leading space it needs — Apple's own sample appends them with no separator
    /// at all. Nemotron finalizes a whole utterance at a time and hands over a
    /// bare sentence, which needs one.
    ///
    /// Getting this backwards is not a formatting nit. Adding a space to segments
    /// that already have their own puts one inside every Chinese sentence and, at
    /// a boundary Apple did not draw between words, inside an English one too.
    var segmentsCarryTheirOwnSpacing: Bool { get }

    /// Get whatever this engine needs for `language` — weights, assets,
    /// reservations — without opening the microphone.
    func prepare(language: String) async throws

    /// Begin accepting audio through `feed`.
    func startStream() async throws

    /// One chunk of 16 kHz mono audio from the router.
    func feed(_ chunk: AudioChunk)

    /// Stop taking audio. A trailing finalize may still arrive afterwards.
    func closeInput()

    /// Wait until every result this engine is going to produce has been
    /// delivered.
    ///
    /// The engines answer this very differently, which is why it is theirs to
    /// answer rather than a fixed sleep in the session. Nemotron's pipeline hops
    /// to the MainActor on its own schedule and offers nothing to await, so it
    /// waits out a measured window. The Speech framework has a real completion —
    /// `finalizeAndFinishThroughEndOfInput()` returns when analysis is done and
    /// the results sequence then ends — so it waits for exactly that and usually
    /// returns much sooner.
    ///
    /// Getting this wrong loses whole dictations: a fixed window that expires
    /// before the last final arrives means `release()` cancels the results task
    /// with the user's only sentence still in it.
    func drain() async

    /// Give back anything shared and tear down anything private.
    func release()
}

/// Bounds how long the dictation flow will wait for something it does not
/// control.
///
/// Two places need this and they need it for the same reason: a model download
/// or an analyzer finalize can fail to return, and the user is holding a hotkey
/// panel open in another application while it does not. Neither wait may be
/// unbounded, and a second private copy of the same task group had already been
/// written once.
enum Deadline {
    /// Run `work`, giving up after `limit`. Whichever finishes first wins and
    /// the other is cancelled.
    ///
    /// `nonisolated`/`@Sendable` so the sleeping task does not queue behind the
    /// MainActor — which would make the deadline unenforceable in exactly the
    /// case it exists for: a MainActor-isolated task that is not yielding.
    static func run(_ limit: Duration, _ work: @escaping @Sendable () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(for: limit) }
            await group.next()
            group.cancelAll()
        }
    }
}

enum DictationEngineError: LocalizedError {
    case modelUnavailable
    case localeUnsupported(String)
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "語音模型載入失敗 ASR model failed to load"
        case let .localeUnsupported(code):
            return "此引擎不支援「\(code)」 Language not supported by this engine"
        case .captureFailed:
            return "無法開始錄音 Could not start recording"
        }
    }
}

/// The bundled NVIDIA Nemotron model, borrowed from the app's single
/// `NemotronStreamingService`.
///
/// Borrowing rather than owning is what keeps dictation from loading a second
/// copy of the ~600 MB weights. It is safe because a meeting and a dictation are
/// mutually exclusive, which the callers enforce — and every borrow made here is
/// given back in `release()`, including the ones an earlier version forgot: the
/// load-progress handler and the recognizer's language/scenario/diarization
/// configuration, which `downloadAllModels` does not restore for us.
@MainActor
final class NemotronDictationEngine: DictationEngine {

    var onInterim: ((String) -> Void)?
    var onFinalized: ((String) -> Void)?
    var onDownloadProgress: ((Double) -> Void)?

    /// Whole utterances, handed over bare. See the protocol.
    let segmentsCarryTheirOwnSpacing = false

    private let asr: NemotronStreamingService
    private let tier: String

    private var savedHandler: ((TranscriptEvent) -> Void)?
    /// Whether this engine has actually taken over `asr.onEvent`.
    ///
    /// `savedHandler` alone cannot answer that: it is `nil` both before the
    /// takeover and if the previous handler genuinely was nil, and restoring on
    /// the first of those wrote `nil` over the handler `CaptureViewModel` installs
    /// exactly once at init and never re-installs. Stopping while the model was
    /// still loading therefore killed every caption for the rest of the app's
    /// life, silently.
    private var didBorrowHandler = false
    private var savedLoadProgress: ((Double) -> Void)?
    private var didBorrowLoadProgress = false
    private var savedConfiguration: (language: String, scenario: CaptureScenario, diarization: Bool)?

    init(asr: NemotronStreamingService, tier: String) {
        self.asr = asr
        self.tier = tier
    }

    func prepare(language: String) async throws {
        savedConfiguration = (asr.currentLanguage, asr.scenario, asr.diarizationEnabled)
        asr.currentLanguage = language
        // A person dictating, not a video: longer silence before finalizing, and
        // no speaker diarization to pay for when there is only one speaker.
        asr.scenario = .meeting
        asr.diarizationEnabled = false

        savedLoadProgress = asr.onLoadProgress
        didBorrowLoadProgress = true
        asr.onLoadProgress = { [weak self] fraction in
            Task { @MainActor in self?.onDownloadProgress?(fraction) }
        }

        do {
            try await asr.loadModels(tier: tier)
            // A cancel that arrives during the (possibly ~600 MB) variant fetch
            // has to end the session rather than be noticed one step later:
            // `startStream` would otherwise open the microphone for a dictation
            // the user has already stopped.
            try Task.checkCancellation()
            // **Wait for the weights, don't let the first sentence pay for them.**
            // `loadModels` only ensures the files are on disk; the CoreML load and
            // the ANE compile happen on the first audio chunk. A meeting absorbs
            // that — it buffers and replays — but dictation is often one sentence
            // long, and the user spends it talking into a recognizer that is still
            // starting. Awaiting here keeps the panel on its loading state until
            // the model can actually hear, which is what "聆聽中" is supposed to
            // mean. When the Prompt tab has already prewarmed this variant the
            // shared task is finished and this returns at once.
            await asr.warmUpWeights()
            try Task.checkCancellation()
        } catch {
            // Put the configuration back before throwing: it was already
            // overwritten above, and leaving it applied hands the next meeting a
            // dictation-scenario recognizer with diarization off.
            release()
            if error is CancellationError { throw error }
            throw DictationEngineError.modelUnavailable
        }
    }

    func startStream() async throws {
        savedHandler = asr.onEvent
        didBorrowHandler = true
        asr.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        do {
            try await asr.startStream()
        } catch {
            throw DictationEngineError.captureFailed
        }
    }

    func feed(_ chunk: AudioChunk) { asr.feed(chunk) }

    /// Keeps the weights. A dictation is seconds long and is followed by
    /// another; freeing them here made every ⌃⌥Space pay the load again.
    func closeInput() { asr.stopStream(keepModelsResident: true) }

    /// How long to wait for the pipeline's trailing finalize.
    ///
    /// `stopStream()` only breaks the consumer loop; the pipeline then runs one
    /// last `finalizeUtterance` for the audio it has already taken in, decodes it
    /// and hops to the MainActor. That is the sentence being spoken when the key
    /// was pressed. The meeting path waits 600 ms for exactly this, and dictation
    /// needs it more, not less: a meeting that loses its last sentence still has
    /// the rest, while a dictation is often *only* that sentence.
    ///
    /// A sleep rather than an await because there is nothing to await — the
    /// pipeline signals completion only by calling `onEvent`.
    private static let drainWindow: Duration = .milliseconds(600)

    func drain() async {
        try? await Task.sleep(for: Self.drainWindow)
    }

    func release() {
        if didBorrowLoadProgress {
            asr.onLoadProgress = savedLoadProgress
            savedLoadProgress = nil
            didBorrowLoadProgress = false
        }
        // Only give back a handler this engine actually took.
        if didBorrowHandler {
            asr.onEvent = savedHandler
            savedHandler = nil
            didBorrowHandler = false
        }
        if let saved = savedConfiguration {
            asr.currentLanguage = saved.language
            asr.scenario = saved.scenario
            asr.diarizationEnabled = saved.diarization
            savedConfiguration = nil
        }
    }

    private func handle(_ event: TranscriptEvent) {
        switch event {
        case let .interim(text, _, _):
            onInterim?(text)
        case let .finalized(segment):
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            onFinalized?(text)
        }
    }
}
