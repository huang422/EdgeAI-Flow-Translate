import AVFoundation
import Foundation
import FlowTranslateCore
import os

/// One microphone-only dictation session, shared by the Prompt tab and the global
/// dictation hotkey.
///
/// It owns everything that is the same whichever recognizer is in use — the
/// microphone permission, the `AudioRouter` borrow, the warming/listening state
/// machine and the drain window — and delegates the recognition itself to a
/// `DictationEngine`. Which engine that is comes from
/// `DictationEngineChoice`: macOS 26's built-in `DictationTranscriber` where it
/// exists, the bundled Nemotron model otherwise.
///
/// **Nothing downstream knows or cares.** Both engines report through the same
/// `onInterim` / `onFinalized` callbacks, so the script guard, the spoken-noise
/// cleaner, the whole-passage Qwen repair and the cursor insertion are byte-for-
/// byte the same path either way.
///
/// It captures through the app's one `AudioRouter`, borrowing it the way the
/// Nemotron engine borrows `asr.onEvent`. The router is where input gets its
/// fixed gain, its auto-gain, its soft limiter and its source tag — a private
/// `MicCapture` would deliver the same voice quieter and unprocessed, which is
/// exactly what the voice-activity gate drops and the acoustic model mishears.
///
/// Borrowing is safe because a meeting and a dictation are mutually exclusive,
/// which the callers enforce.
@MainActor
final class DictationSession {

    enum State: Equatable {
        case idle
        /// Weights are loading. Reported honestly instead of pretending to listen.
        case warming
        case listening
    }

    private(set) var state: State = .idle

    /// Fires for each finalized sentence.
    var onFinalized: ((String) -> Void)?
    /// Fires as the current sentence evolves.
    var onInterim: ((String) -> Void)?
    var onStateChange: ((State) -> Void)?
    /// Fraction of the recognizer's assets downloaded, while that is happening.
    ///
    /// The first dictation on a fresh install fetches hundreds of megabytes
    /// before it can hear anything — Nemotron's weights, or the built-in
    /// recognizer's locale assets. Without this the panel said "載入模型" and sat
    /// there with no sign of progress, which is indistinguishable from a hang.
    var onDownloadProgress: ((Double) -> Void)?

    /// Builds the engine for this session. A factory rather than an instance so
    /// the choice is re-read at every start — switching it in Settings takes
    /// effect on the next dictation, not the next launch.
    private let makeEngine: @MainActor () -> DictationEngine
    /// The app's one audio router — the same object a meeting captures through.
    private let router: AudioRouter

    private var engine: DictationEngine?
    private var savedChunkHandler: ((AudioChunk) -> Void)?
    private var didBorrowRouter = false

    /// Audio chunks handed to the engine this session.
    ///
    /// The difference between "the microphone is not delivering" and "you have
    /// not said anything yet" — two situations that look identical on the panel
    /// and need opposite responses from the user. It has been zero for a whole
    /// session before, on a capture that started without error, and nothing
    /// anywhere said so.
    ///
    /// **Locked**, because it is written from the capture thread and read on the
    /// MainActor. Left as a plain property on a `@MainActor` class it is a torn
    /// read: the watchdog can see zero while audio is arriving, decide the
    /// microphone is dead, and replace the transcript on the panel with a warning
    /// about it. A wrong answer here is worse than no answer, because it lands on
    /// top of the thing the user is reading.
    private let feedLock = NSLock()
    private var chunksFedStorage = 0

    private func countChunk() {
        feedLock.withLock { chunksFedStorage += 1 }
    }

    /// Whether audio is actually arriving. Read by the panel after the grace
    /// period below.
    var isReceivingAudio: Bool { feedLock.withLock { chunksFedStorage > 0 } }

    /// Whether the running engine's segments already carry their own spacing.
    /// Nil before one exists; the caller keeps its previous answer then.
    var segmentsCarryTheirOwnSpacing: Bool? { engine?.segmentsCarryTheirOwnSpacing }

    /// How long a listening session may deliver nothing before that is worth
    /// reporting. Long enough to cover the first buffer on a cold device, short
    /// enough that a user is still holding the key when they are told.
    static let silentStartGrace: Duration = .seconds(3)

    private static let log = Logger(subsystem: "dev.flowtranslate.app", category: "prompt")

    init(router: AudioRouter, makeEngine: @escaping @MainActor () -> DictationEngine) {
        self.router = router
        self.makeEngine = makeEngine
    }

    enum StartError: LocalizedError {
        case microphoneDenied

        var errorDescription: String? {
            switch self {
            case .microphoneDenied: return "需要麥克風權限 Microphone permission required"
            }
        }
    }

    func start(language: String) async throws {
        // Belt and braces against a second caller: two sessions would each borrow
        // the router's chunk sink and start a recognizer, corrupting the handler
        // chain when the first one stops.
        guard state == .idle else { return }
        guard await Permissions.ensureMicrophone() else { throw StartError.microphoneDenied }

        set(.warming)
        let engine = makeEngine()
        self.engine = engine
        engine.onDownloadProgress = { [weak self] fraction in
            Task { @MainActor in self?.onDownloadProgress?(fraction) }
        }
        engine.onInterim = { [weak self] text in self?.onInterim?(text) }
        engine.onFinalized = { [weak self] text in
            // Forwarded **as the engine produced it**, only skipped when there is
            // nothing in it. Trimming was destroying the leading space Apple's
            // recognizer puts on a segment — the very thing that says where the
            // join goes — and the caller was then adding a space of its own to
            // compensate, which is how a space ended up inside Chinese sentences
            // and inside English words split at a segment boundary. See
            // `DictationEngine.segmentsCarryTheirOwnSpacing`.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            self?.onFinalized?(text)
        }

        do {
            try await engine.prepare(language: language)
        } catch {
            // `teardown`, not `set(.idle)`: the engine may already have taken
            // shared state, and leaving it applied hands the next meeting a
            // dictation-configured recognizer.
            teardown()
            Self.log.error("dictation prepare failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        // Re-check after the await. `stop()` or `cancelAndDrain()` during model
        // loading already ran `teardown()` — it set `.idle` and released the
        // engine — but this continuation knows nothing about that. Carrying on
        // from here re-borrowed shared state from a *meeting* that had since
        // started, opened a second microphone, and routed every finalized segment
        // into the prompt draft. The meeting produced no captions at all.
        guard state == .warming else {
            teardown()
            throw DictationEngineError.captureFailed
        }

        savedChunkHandler = router.onChunk
        didBorrowRouter = true
        feedLock.withLock { chunksFedStorage = 0 }
        router.onChunk = { [weak self] chunk in
            guard let self else { return }
            self.countChunk()
            self.engine?.feed(chunk)
        }

        do {
            try await engine.startStream()
            // Through the router, so this is byte-for-byte the path a meeting's
            // microphone takes: same capture, same gain, same source tag.
            try await router.enable(.microphone)
            set(.listening)
        } catch {
            teardown()
            Self.log.error("dictation capture failed: \(error.localizedDescription, privacy: .public)")
            throw DictationEngineError.captureFailed
        }
    }

    /// Abandon the session immediately. Anything still being decoded is lost,
    /// which is what the cancel paths want.
    func stop() {
        guard state != .idle else { return }
        closeInput()
        restoreBorrowedState()
        set(.idle)
    }

    /// Stop taking audio, but stay wired up so the trailing finalize still
    /// arrives.
    ///
    /// Separate from `settle()` so the microphone closes the instant the user
    /// presses the key — the recording light going out is the feedback that the
    /// key registered, and it must not wait on a drain.
    func closeInput() {
        guard state != .idle else { return }
        closeInputStreams()
    }

    /// Let the engine finish delivering, then give back everything this session
    /// borrowed.
    ///
    /// Without this pair, the callers read their transcript in the same turn they
    /// called stop, so the last utterance was never in it — and worse, by then
    /// the shared handler had already been restored, so that utterance was
    /// delivered to the meeting view model, which drops it because no meeting is
    /// running. A short dictation is frequently one sentence, which made the
    /// feature look as if it had done nothing at all.
    ///
    /// The wait belongs to the engine (`drain()`), not to this method: one of
    /// them has a real completion to await and the other only a measured window,
    /// and hard-coding the window here meant the engine with the real answer was
    /// cut off by the wrong one.
    func settle() async {
        guard state != .idle else { return }
        closeInputStreams()
        await engine?.drain()
        restoreBorrowedState()
        set(.idle)
    }

    private func closeInputStreams() {
        if didBorrowRouter { router.disable(.microphone) }
        engine?.closeInput()
    }

    private func restoreBorrowedState() {
        if didBorrowRouter {
            router.onChunk = savedChunkHandler
            savedChunkHandler = nil
            didBorrowRouter = false
        }
        engine?.release()
        engine = nil
    }

    private func teardown() {
        closeInputStreams()
        restoreBorrowedState()
        set(.idle)
    }

    private func set(_ next: State) {
        guard state != next else { return }
        state = next
        onStateChange?(next)
    }

}
