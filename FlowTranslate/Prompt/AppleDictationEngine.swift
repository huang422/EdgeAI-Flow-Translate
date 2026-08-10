import AVFoundation
import Foundation
import FlowTranslateCore
import Speech
import os

/// macOS 26's built-in on-device recognizer, driven through `SpeechAnalyzer`.
///
/// `DictationTranscriber` rather than `SpeechTranscriber`: the two differ in what
/// they are tuned for, and this flow is dictation by definition — a person
/// talking to their own machine, close-mic, expecting punctuation. It is the
/// module Apple's own dictation uses, and it is the one that takes content hints.
///
/// **Dictation only, by design.** It reports no speaker identity, so putting it
/// behind the captions would delete the diarized names from the transcript, the
/// summary and every export. `DictationEngineChoice` documents that boundary.
///
/// Everything after recognition is unchanged: the text goes to the same
/// `DictationSession` callbacks that Nemotron's does, so the script guard, the
/// spoken-noise cleaner, the whole-passage Qwen repair and the cursor insertion
/// all run exactly as before. This class ends at the words.
///
/// **Offline once installed, like everything else here.** Recognition is
/// on-device with no server path — the framework makes no network call to
/// transcribe. What *is* fetched is the per-language asset, once, through
/// `AssetInventory`; `prepare` does that explicitly and reports progress rather
/// than letting it happen invisibly on the first utterance. After that the
/// engine works with no network at all, which is the same contract the Nemotron
/// path has with its downloaded variant.
@available(macOS 26.0, *)
@MainActor
final class AppleDictationEngine: DictationEngine {

    var onInterim: ((String) -> Void)?
    var onFinalized: ((String) -> Void)?
    var onDownloadProgress: ((Double) -> Void)?

    /// `DictationTranscriber` results arrive with their own leading spacing, and
    /// Apple's own sample appends them with no separator. See the protocol.
    let segmentsCarryTheirOwnSpacing = true

    private var analyzer: SpeechAnalyzer?
    private var transcriber: DictationTranscriber?
    private var resultsTask: Task<Void, Never>?
    private var reservedLocale: Locale?

    /// The format the analyzer asked for.
    ///
    /// The router hands out 16 kHz mono Float32 — what Nemotron wants — and the
    /// analyzer picks its own preferred format, which is not guaranteed to be the
    /// same. Converting per chunk is cheap next to recognition, and feeding the
    /// wrong format is not a degraded result but a rejected one.
    private var analyzerFormat: AVAudioFormat?

    /// Everything the audio thread touches, and nothing the audio thread does not.
    ///
    /// **This is why words went missing.** `feed(_:)` is called by the router
    /// straight from the capture callback — an audio thread — while this class is
    /// `@MainActor`. So the continuation, the target format and the
    /// `AVAudioConverter` were all being read *and written* from that thread
    /// (`converter` is created lazily inside the conversion) at the same time the
    /// MainActor could be running `prepare()` or `release()` on them. An
    /// `AVAudioConverter` is a stateful resampler; two threads inside one is not
    /// a degraded conversion but a corrupted one, and a converter swapped or
    /// nilled mid-chunk simply loses the audio in it.
    ///
    /// The Nemotron path never had this: it feeds `NemotronStreamingService`,
    /// which is built for audio-thread access and guards its state with a lock.
    /// This engine was the odd one out, which is exactly the shape of "the Mac
    /// model drops words and Nemotron does not".
    private let sink = AudioSink()

    private static let log = Logger(subsystem: "dev.flowtranslate.app", category: "prompt")

    /// Whether this system has the built-in recognizer at all.
    ///
    /// Checked against `supportedLocales` rather than only the OS version: the
    /// API exists on every macOS 26 install, and the assets do not exist on all
    /// of them (they follow the languages the user has set up).
    static func isAvailable() async -> Bool {
        await !DictationTranscriber.supportedLocales.isEmpty
    }

    /// Which of `languages` this engine already has assets on disk for.
    ///
    /// This is the answer to "the Mac has this recognizer built in — does it
    /// still download anything?". The *framework* ships with the OS; the
    /// per-language assets do not, and the system fetches them on first use.
    /// A language already set up in System Settings → Keyboard → Dictation is
    /// present here and costs nothing; one that is not is a one-time system
    /// download, which `prepare` reports through `onDownloadProgress`.
    ///
    /// Both sides of the comparison are locales the framework itself returned,
    /// never a string this app wrote. `Locale.identifier` is not a stable
    /// spelling — `zh-TW` and `zh_TW` are the same locale — so comparing our own
    /// codes against `installedLocales` would have answered "not installed" for
    /// a language that is, and shown a download marker beside it forever.
    static func installedLanguages(among languages: [String]) async -> Set<String> {
        let installed = Set(await DictationTranscriber.installedLocales.map(\.identifier))
        var result: Set<String> = []
        for language in languages {
            // Through the same resolver the session uses, so the marker answers
            // for the locale that will actually run — `auto` in particular, which
            // resolves to a preferred language rather than to itself.
            guard let resolved = await resolvedLocale(for: language) else { continue }
            if installed.contains(resolved.identifier) { result.insert(language) }
        }
        return result
    }

    /// Get the assets for `language` on disk without opening a session.
    ///
    /// The built-in recognizer's equivalent of Nemotron's variant prewarm, and it
    /// exists for the same reason: opening the Prompt tab is the user saying they
    /// are about to dictate, and the first ⌃⌥Space should not be the moment a
    /// per-language asset is fetched. There is no weight-loading step to do ahead
    /// of time here — the system holds the model — so this ends at the download.
    ///
    /// Silent about failure on purpose: nothing is broken if it does not finish,
    /// the session's own `prepare` will do it again and that one has a panel to
    /// report on.
    static func prewarm(language: String) async {
        guard let locale = await resolvedLocale(for: language) else { return }
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        // Nil is the common case and not a failure: it means the assets are
        // already installed and there is nothing to fetch.
        guard let request = try? await AssetInventory
            .assetInstallationRequest(supporting: [transcriber])
        else { return }
        try? await request.downloadAndInstall()
        log.info("prewarmed built-in assets for \(locale.identifier, privacy: .public)")
    }

    // MARK: - DictationEngine

    func prepare(language: String) async throws {
        guard let locale = await Self.resolvedLocale(for: language) else {
            throw DictationEngineError.localeUnsupported(language)
        }
        Self.log.notice("recognizing as \(locale.identifier, privacy: .public)")
        // Checked between every step, not only at the top. A cancel arriving
        // while the asset download runs has to end the session, and the only way
        // it can is if this function stops on the way back out — otherwise the
        // caller's `await` is holding the panel open for the length of a download
        // nobody is waiting for any more.
        try Task.checkCancellation()

        // Apple's own preset for this exact flow, rather than four option sets
        // assembled by hand.
        //
        // They turn out to be the same thing — `progressiveLongDictation` is
        // `punctuation` + `volatileResults` with no content hints, which is
        // character for character what was written here before, and worth
        // recording because it says the configuration was never the reason
        // recognition disappointed. What the named preset buys is that it stays
        // Apple's answer: `shortDictation` and `phrase` each carry a content hint
        // this flow must not have (they are tuned for a few words), and if Apple
        // revises what long progressive dictation should ask for, this follows.
        //
        // "Progressive" is the half that makes the live line live: without
        // volatile results nothing is reported until a segment finalizes and the
        // panel sits blank while the user talks. "Long" is the other half — the
        // short presets assume a phrase, and this flow is a paragraph.
        let transcriber = DictationTranscriber(
            locale: locale, preset: .progressiveLongDictation
        )

        // Reserve before installing: the reservation is what stops the system
        // reclaiming the assets we are about to download. Failure is not fatal —
        // it means the reservation slots are full, and the assets may well still
        // be present — so it is logged rather than thrown.
        do {
            try await AssetInventory.reserve(locale: locale)
            reservedLocale = locale
        } catch {
            Self.log.info("locale reservation refused: \(error.localizedDescription, privacy: .public)")
        }

        try Task.checkCancellation()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await download(request)
        }
        try Task.checkCancellation()

        self.transcriber = transcriber
        // Resolved here, handed to the sink at `startStream`. The sink builds its
        // converter from it once, off the audio thread.
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    }

    func startStream() async throws {
        guard let transcriber else { throw DictationEngineError.modelUnavailable }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        sink.open(continuation: continuation, target: analyzerFormat)

        // Consume results before starting, so nothing produced between `start`
        // returning and the loop being scheduled is dropped.
        //
        // The loop runs **on the MainActor**, rather than hopping to it once per
        // result. `await MainActor.run` inside the loop meant every result — and
        // volatile results arrive several times a second — waited for the
        // MainActor before the next one could even be read, so a busy UI became
        // back-pressure on the analyzer's own output. Suspending in `for try
        // await` releases the MainActor between results just as effectively and
        // keeps delivery in order, which per-result `Task { @MainActor }` would
        // not.
        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    // **Not trimmed.** The leading space Apple puts on a segment
                    // is the join between it and the one before, and trimming it
                    // away left the caller guessing where words end — inserting a
                    // space inside every Chinese sentence, and inside any English
                    // one whose segment boundary fell mid-word.
                    let text = String(result.text.characters)
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { continue }
                    guard let self else { return }
                    // Apple reports finals per *segment*, so they accumulate
                    // the same way Nemotron's finalized utterances do — which
                    // is why both engines can share one set of callbacks.
                    if result.isFinal { self.onFinalized?(text) } else { self.onInterim?(text) }
                }
            } catch {
                Self.log.error("analyzer results ended: \(error.localizedDescription, privacy: .public)")
            }
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            Self.log.error("analyzer start failed: \(error.localizedDescription, privacy: .public)")
            throw DictationEngineError.captureFailed
        }
    }

    /// `nonisolated`, because it is called from the audio thread and must not
    /// pretend otherwise. Everything it touches lives in `sink`.
    nonisolated func feed(_ chunk: AudioChunk) {
        sink.feed(chunk.samples)
    }

    func closeInput() {
        sink.close()
    }

    /// Longest this will wait for the tail before giving up on it.
    ///
    /// A bound is required, not a nicety: `finalizeAndFinishThroughEndOfInput()`
    /// is the analyzer's promise to finish, and a wedged analyzer would otherwise
    /// hold the panel — and the user's clipboard flow — open indefinitely. Three
    /// seconds is far past a normal finalize and still short enough to read as
    /// slow rather than hung.
    private static let maxDrain: Duration = .seconds(3)

    func drain() async {
        guard let analyzer else { return }
        // Awaited, not fired and forgotten. An earlier version started the
        // finalize in a detached Task and let the session sleep a fixed 600 ms —
        // and on macOS 26 this is the *default* engine, so any finalize slower
        // than that window (a first-run asset load, a busy machine) had its
        // result cancelled by `release()` with the user's only sentence in it.
        //
        // Two things have to complete: the analyzer, and the loop reading its
        // results. The results sequence terminates when the analyzer finishes, so
        // awaiting the task is what guarantees the last `onFinalized` has already
        // been delivered.
        let results = resultsTask
        await Deadline.run(Self.maxDrain) {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            await results?.value
        }
    }

    func release() {
        resultsTask?.cancel()
        resultsTask = nil
        sink.close()
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        transcriber = nil
        analyzerFormat = nil
        if let reservedLocale {
            Task { await AssetInventory.release(reservedLocale: reservedLocale) }
            self.reservedLocale = nil
        }
    }

    // MARK: - Assets

    private func download(_ request: AssetInstallationRequest) async throws {
        let progress = request.progress
        // Polled rather than observed: `Progress` is KVO-only, and one timer for
        // the length of a download is less machinery than a KVO bridge that has
        // to be torn down on three different exit paths.
        let reporter = Task { [weak self] in
            while !Task.isCancelled {
                let fraction = progress.fractionCompleted
                await MainActor.run { self?.onDownloadProgress?(fraction) }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { reporter.cancel() }
        // Cancelling the enclosing task has to reach the download itself, not
        // just the `await` in front of it. `Progress.cancel()` is what the
        // framework watches; without this hook a ⌃⌥Space pressed to stop a
        // first-run asset fetch left it running to completion with the panel
        // stuck on its percentage.
        try await withTaskCancellationHandler {
            try await request.downloadAndInstall()
        } onCancel: {
            progress.cancel()
        }
        onDownloadProgress?(1)
    }

    // MARK: - Audio

    /// Which locale to ask for.
    ///
    /// A named language is taken at its word. `"auto"` is the interesting case.
    ///
    /// **`DictationTranscriber` has no mixed mode.** It takes exactly one locale
    /// for the whole session, so `auto` *cannot* mean what the picker's 混說 label
    /// promises. Resolving it to `Locale.current` — the Mac's **interface**
    /// language — is the trap: on a Mac localized to Traditional Chinese that pins
    /// the recognizer to `zh-TW` whatever the user is saying, and nothing on
    /// screen says so, because the setting is the default, the label says "Mixed",
    /// and the resolved locale is never
    /// surfaced anywhere.
    ///
    /// So `auto` now resolves through the languages the user has actually asked
    /// macOS for, in their own order of preference, and takes the first one this
    /// recognizer **already has installed**. An installed language is one the
    /// user set up in System Settings → Keyboard → Dictation, which is a far
    /// better statement of what they intend to dictate in than which language the
    /// menus are drawn in. `Locale.current` remains the last resort.
    ///
    /// This still cannot recognize two languages at once. Where that matters,
    /// Nemotron's multilingual weights genuinely can, and the engine picker is
    /// how you get them.
    static func resolvedLocale(for language: String) async -> Locale? {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != "auto" {
            return await DictationTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: trimmed))
        }

        let installed = Set(await DictationTranscriber.installedLocales.map(\.identifier))
        for preferred in Locale.preferredLanguages {
            guard let supported = await DictationTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: preferred)),
                  installed.contains(supported.identifier)
            else { continue }
            return supported
        }
        return await DictationTranscriber.supportedLocale(equivalentTo: Locale.current)
    }


}

// MARK: - Audio sink

/// The audio-thread half of `AppleDictationEngine`: the analyzer's input
/// continuation, the format it wants, and the converter into it.
///
/// A separate object with its own lock, because `feed(_:)` arrives on the
/// capture thread and everything here is also written from the MainActor when a
/// session starts and ends. One lock covers all three, which is what makes
/// "opened", "converting" and "closed" a single state rather than three that can
/// disagree — the converter being created while another thread nils it was how
/// audio went missing.
///
/// `@unchecked Sendable` and hand-locked rather than an actor: `feed` must not
/// suspend. It runs inside a Core Audio callback, where waiting on an actor hop
/// is how you get a glitch instead of a word.
@available(macOS 26.0, *)
private final class AudioSink: @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var target: AVAudioFormat?
    private var converter: AVAudioConverter?

    /// Chunks the converter refused, so a silent failure is still countable.
    private var droppedChunks = 0

    private static let log = Logger(subsystem: "dev.flowtranslate.app", category: "prompt")

    /// What the router delivers: 16 kHz mono Float32.
    private static let captureFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )

    /// Start accepting audio for `target`, building the converter up front rather
    /// than on the first chunk — so the audio thread never allocates one.
    func open(continuation: AsyncStream<AnalyzerInput>.Continuation, target: AVAudioFormat?) {
        let converter = Self.makeConverter(to: target)
        let needed = target != nil && target != Self.captureFormat
        lock.withLock {
            self.continuation = continuation
            self.target = target
            self.converter = converter
            self.needsConversion = needed
            self.droppedChunks = 0
        }
        if needed, converter == nil {
            Self.log.error("no converter to the analyzer's format; audio cannot be delivered")
        }
        if let target, let capture = Self.captureFormat, target != capture {
            Self.log.info("""
                analyzer wants \(target.sampleRate, privacy: .public) Hz \
                \(target.channelCount, privacy: .public)ch; converting from 16 kHz mono
                """)
        }
    }

    /// Stop accepting audio and end the analyzer's input sequence.
    func close() {
        let (finished, dropped) = lock.withLock { () -> (AsyncStream<AnalyzerInput>.Continuation?, Int) in
            let c = continuation
            continuation = nil
            converter = nil
            target = nil
            needsConversion = false
            return (c, droppedChunks)
        }
        finished?.finish()
        if dropped > 0 {
            Self.log.notice("dictation dropped \(dropped, privacy: .public) audio chunks")
        }
    }

    /// One chunk of 16 kHz mono audio, from the capture thread.
    func feed(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        let buffer = makeBufferLocked(from: samples)
        if buffer == nil { droppedChunks += 1 }
        lock.unlock()
        guard let buffer else { return }
        continuation.yield(AnalyzerInput(buffer: buffer))
    }

    /// Whether the analyzer's format differs from what the router delivers, so a
    /// converter is **required** rather than merely available.
    ///
    /// Kept apart from `converter` being non-nil because the two can disagree,
    /// and the disagreement is silent and total: `AVAudioConverter(from:to:)` is
    /// failable, so a conversion the system will not build leaves a nil converter
    /// beside a target that still needs one. Feeding the analyzer our own format
    /// then — 16 kHz Float32 where it asked for 16 kHz Int16 — is not a degraded
    /// result but no result at all, and nothing in the flow would have said why.
    private var needsConversion = false

    private static func makeConverter(to target: AVAudioFormat?) -> AVAudioConverter? {
        guard let capture = captureFormat, let target, target != capture else { return nil }
        return AVAudioConverter(from: capture, to: target)
    }

    /// Caller holds `lock`.
    private func makeBufferLocked(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let captureFormat = Self.captureFormat,
              let source = AVAudioPCMBuffer(
                  pcmFormat: captureFormat, frameCapacity: AVAudioFrameCount(samples.count)
              )
        else { return nil }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input in
            source.floatChannelData?[0].update(from: input.baseAddress!, count: samples.count)
        }

        // The analyzer takes what the router already produces, so hand it over
        // unconverted. Measured: `DictationTranscriber` asks for 16 kHz mono, the
        // same rate the router delivers, so nothing is ever resampled here and no
        // band is lost — only the sample type differs.
        guard needsConversion else { return source }
        // Required but unavailable. Dropping the chunk is the honest outcome:
        // `close()` reports the count, where feeding the wrong format would leave
        // a recognizer that simply never answers.
        guard let converter, let target else { return nil }

        let ratio = target.sampleRate / captureFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
        else { return nil }

        var consumed = false
        var error: NSError?
        // `AVAudioConverterInputBlock` is typed `@Sendable`, and `AVAudioPCMBuffer`
        // is not `Sendable`, so handing the buffer to the block is a warning by
        // construction. It is safe here for a reason the type system cannot see:
        // the block is called synchronously, on this thread, from inside the
        // `convert` call below, and `source` outlives it and is touched by nobody
        // else.
        nonisolated(unsafe) let input = source
        let status = converter.convert(to: output, error: &error) { _, status in
            // One input buffer, once. Reporting `.haveData` a second time makes
            // the converter ask for the same samples again and emit them twice.
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        // `.inputRanDry` is the normal outcome and not a failure: a resampler
        // needs lookahead, so it keeps the tail of this chunk and emits it with
        // the next one. `.error` is a failure, and inspecting only `error` makes a
        // converter that has stopped producing look exactly like quiet audio.
        if status == .error || error != nil {
            Self.log.error("""
                audio conversion failed: \(error?.localizedDescription ?? "unknown", privacy: .public)
                """)
            return nil
        }
        return output.frameLength > 0 ? output : nil
    }
}
