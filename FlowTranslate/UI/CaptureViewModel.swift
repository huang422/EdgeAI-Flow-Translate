import Foundation
import Combine
import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers
import Translation
import OSLog
import FlowTranslateCore

struct CaptionLine: Identifiable, Equatable {
    let id: UUID
    var english: String
    var chinese: String?
}

/// Wires audio capture → Nemotron ASR → translation → bilingual captions /
/// transcript / summary (P1–P4 integration).
@MainActor
final class CaptureViewModel: ObservableObject {
    static let log = Logger(subsystem: "dev.flowtranslate.app", category: "model")

    // Audio sources
    @Published var micEnabled = false
    @Published var systemEnabled = false
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0

    // Recognition / captions
    @Published var asrState: ASRState = .idle
    @Published var interimText = ""
    @Published var interimChinese = ""
    @Published var lines: [CaptionLine] = []
    @Published var statusMessage = "Idle"

    // Meeting / summary / overlay
    @Published var overlayOn = false
    @Published var summaryText = ""
    @Published var isSummarizing = false

    /// Human-readable second-caption status (language pair + translation method).
    @Published var translationStatus = ""

    /// Model download/prefetch status (e.g. the Qwen model fetched at Start).
    @Published var modelStatus = ""

    enum TranslationMethod { case none, apple, mlx }
    private var translationMethod: TranslationMethod = .apple
    private var mlxTranslator: MLXTranslator?

    // Echo suppression: when system audio is playing through speakers, the mic
    // mostly hears that same audio → skip mic input to avoid garbled double
    // captions. (Accessed from the audio threads, so lock-protected.)
    private let echoLock = NSLock()
    private var lastSystemVoiceAt = Date.distantPast
    private var systemSourceOn = false

    // Serializes translation-backend resolution (avoids overlapping availability
    // checks when settings change rapidly).
    private var availabilityTask: Task<Void, Never>?
    // Lazy Qwen memory-load: started by the first sentence that needs the model
    // (during a meeting), never at app launch. Shared so concurrent sentences
    // load it once. The files are pre-downloaded to disk at meeting Start.
    private var qwenLoadTask: Task<Void, Never>?
    // Background download-to-disk of the Qwen model, kicked off at meeting Start
    // (like the ASR model) so there's no surprise download mid-meeting.
    private var qwenPrefetchTask: Task<Void, Never>?

    /// Free the Qwen model from **memory** and reset its load state. The disk
    /// prefetch is intentionally left running — the summary needs those files even
    /// after translation switches to Apple or the meeting ends.
    private func unloadQwen() {
        mlxTranslator?.unload()
        qwenLoadTask?.cancel(); qwenLoadTask = nil
    }

    /// At meeting Start, download the Qwen model files to disk in the background
    /// (like the ASR model). Always runs: even if translation uses Apple, the
    /// end-of-meeting **summary** uses the same Qwen model. Memory load stays lazy.
    /// The translator and summarizer share the same model id, so this one download
    /// serves both. Download-only — no memory is used until something loads it.
    private func prefetchQwen() {
        let translator = mlxTranslator ?? MLXTranslator()
        mlxTranslator = translator
        guard !translator.isLoaded, qwenPrefetchTask == nil else { return }
        qwenPrefetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Clear the handle when done so a later Start can resume an incomplete
            // download (the downloader skips files already fetched at full size).
            defer { self.qwenPrefetchTask = nil }
            do {
                try await translator.prefetch { p in
                    Task { @MainActor in
                        self.modelStatus = "下載 Qwen 模型（翻譯／摘要用）… \(Int(p * 100))%"
                    }
                }
                self.modelStatus = "Qwen 模型已下載（用到時載入記憶體）"
            } catch {
                Self.log.error("Qwen prefetch failed: \(String(reflecting: error), privacy: .public)")
                self.modelStatus = "Qwen 模型下載失敗：\(String(describing: error))"
            }
        }
    }

    /// Load the Qwen model into memory on demand (guarded so it loads exactly
    /// once), showing live progress. Files are normally already on disk (fetched
    /// at Start), so this is just a memory load. Returns whether the model is ready.
    private func ensureQwenReady(_ translator: MLXTranslator, srcName: String, tgtName: String) async -> Bool {
        if translator.isLoaded { return true }
        if qwenLoadTask == nil {
            qwenLoadTask = Task { @MainActor [weak self] in
                guard let self else { return }
                self.translationStatus = "第二字幕：\(srcName) → \(tgtName) · Qwen 模型載入中…"
                // Wait for the at-Start disk prefetch (if any) so we don't download twice.
                await self.qwenPrefetchTask?.value
                do {
                    try await translator.ensureLoaded { p in
                        Task { @MainActor in
                            self.translationStatus = "第二字幕：\(srcName) → \(tgtName) · Qwen 模型載入中… \(Int(p * 100))%"
                        }
                    }
                    self.translationStatus = "第二字幕：\(srcName) → \(tgtName) · Qwen 模型翻譯（已載入）"
                } catch {
                    Self.log.error("Qwen load failed: \(String(reflecting: error), privacy: .public)")
                    self.translationStatus = "第二字幕：Qwen 載入失敗（\(String(describing: error))），第一字幕正常"
                }
            }
        }
        await qwenLoadTask?.value
        return translator.isLoaded
    }

    // User settings (persisted). Applied to the live pipeline on change.
    @Published var settings: CaptionSettings = SettingsStore.load() {
        didSet { applySettings() }
    }

    enum ASRState: Equatable { case idle, loading, listening }

    // Dependencies
    private let router = AudioRouter()
    private let asr = NemotronStreamingService()
    let translation = TranslationService()
    let overlay = OverlayController()
    private let store: TranscriptStoring
    private let cleaner = BasicTextCleaner()
    // MLX Qwen3-1.7B summarizer (on-demand), with the pure-Swift extractive
    // summarizer as an offline / failure fallback.
    private let mlxSummarizer = MLXMeetingSummarizer()
    private let fallbackSummarizer = ExtractiveSummarizer()
    private var segmentIndex = 0
    private var lastSummaryEN: Summary?
    private var lastSummaryZH: Summary?
    /// Id of the sentence currently shown in the floating overlay, so a late
    /// translation only updates the overlay if it still belongs to that sentence.
    private var currentOverlayId: UUID?

    // Live (interim) translation: translate the in-progress sentence on a
    // throttle so the second caption updates in real time, not only on finalize.
    private var currentInterimId: UUID?
    private var pendingInterimText: String?
    private var lastInterimTranslateAt: Date = .distantPast
    private var interimThrottleTask: Task<Void, Never>?
    private var interimInFlight = false
    private let interimTranslateInterval: TimeInterval = 0.2

    /// System-wide shortcut (⌃⌥C) to toggle the floating overlay from any app.
    private var overlayHotKey: GlobalHotKey?

    init() {
        // Persist the transcript to Application Support so an unexpected close
        // does not lose accumulated segments (FR-008).
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FlowTranslate", isDirectory: true)
        store = (try? FileTranscriptStore(directory: dir)) ?? InMemoryTranscriptStore()

        router.onChunk = { [weak self] chunk in
            guard let self else { return }
            let rms = AudioMath.rms(chunk.samples)
            // Always update the level meter (independent of recognition).
            Task { @MainActor in self.updateLevel(chunk.source, rms) }

            let voiced = rms >= 0.012
            if chunk.source == .system {
                if voiced { self.echoLock.withLock { self.lastSystemVoiceAt = Date() } }
                self.asr.feed(chunk)
            } else {
                // Microphone: while system audio is actively playing, what the mic
                // hears is mostly the speakers (echo) → drop it so the same content
                // isn't transcribed twice / garbled. Use the system track instead.
                let systemActiveNow = self.echoLock.withLock {
                    Date().timeIntervalSince(self.lastSystemVoiceAt) < 0.8
                }
                if self.systemSourceOn && systemActiveNow { return }
                self.asr.feed(chunk)
            }
        }
        asr.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        asr.onModelLoading = { [weak self] loading in
            Task { @MainActor in
                guard let self, self.asrState == .listening else { return }
                self.statusMessage = loading
                    ? "辨識模型載入中…（首次較久，請開始說話）"
                    : "辨識中 Listening"
            }
        }
        translation.onResult = { [weak self] id, zh in
            self?.applyTranslation(id: id, chinese: zh)
        }
        translation.onUnavailable = { [weak self] in
            self?.statusMessage = "第二字幕翻譯語言包未安裝，請在彈出視窗允許下載 (System Settings > Translation Languages)"
        }
        applySettings()

        // Global shortcut ⌃⌥C → toggle the floating caption overlay (works even
        // while another app like Zoom is focused). kVK_ANSI_C == 8.
        overlayHotKey = GlobalHotKey(keyCode: 8, modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            Task { @MainActor in self?.toggleOverlay() }
        }
    }

    // MARK: - Settings

    private func applySettings() {
        translation.enabled = settings.needsTranslation
        // "auto" first-caption → let the translator auto-detect the source.
        translation.sourceLanguage = settings.firstLanguage == "auto"
            ? "" : String(settings.firstLanguage.prefix(2))
        translation.targetLanguage = settings.secondLanguage.rawValue
        overlay.model.showSecondLine = settings.secondCaptionEnabled
        overlay.model.fontSize = settings.fontSize
        overlay.updateLayout()   // resize the box stack for one/two captions
        overlay.setClickThrough(settings.clickThrough)
        SettingsStore.save(settings)
        availabilityTask?.cancel()
        availabilityTask = Task { await updateTranslationAvailability() }
    }

    /// Pick the translation backend for the current language pair and update the
    /// live status line. **Apple** (fast, on-device) for a specific source it
    /// supports; the **MLX Qwen** model for "auto" (Apple can't auto-detect) and
    /// for specific pairs Apple doesn't support.
    private func updateTranslationAvailability() async {
        let tgtName = settings.secondLanguage.displayName

        // Off vs. same-language: distinct, clear messages (was a confusing "關閉").
        guard settings.secondCaptionEnabled else {
            translationMethod = .none; translation.enabled = false; unloadQwen()
            translationStatus = "第二字幕：已關閉"
            return
        }
        guard settings.needsTranslation else {
            translationMethod = .none; translation.enabled = false; unloadQwen()
            translationStatus = "第二字幕：來源與目標同為「\(tgtName)」，無需翻譯（請改選不同的目標語言）"
            return
        }

        // Choose the backend. Apple needs a KNOWN source: for "auto" it can't,
        // and pops up a system "choose a language" sheet, so auto always uses the
        // on-device Qwen model. A specific language uses Apple when it supports the
        // pair (covers most languages on macOS 26), else falls back to Qwen.
        let srcName: String
        let useQwen: Bool
        if settings.firstLanguage == "auto" {
            srcName = "自動偵測"
            useQwen = true
        } else {
            srcName = settings.firstLanguage
            let source = Locale.Language(identifier: String(settings.firstLanguage.prefix(2)))
            let target = Locale.Language(identifier: settings.secondLanguage.rawValue)
            useQwen = await LanguageAvailability().status(from: source, to: target) == .unsupported
        }

        if !useQwen {
            translationMethod = .apple
            translation.enabled = true
            unloadQwen()
            translationStatus = "第二字幕：\(srcName) → \(tgtName) · Apple 系統翻譯（即時）"
            return
        }

        // On-device Qwen model. Selected now, but loaded into memory LAZILY — only
        // when the first sentence actually needs translating (files are fetched to
        // disk at meeting Start). Never loaded at app launch / while idle.
        translation.enabled = false
        let translator = mlxTranslator ?? MLXTranslator()
        mlxTranslator = translator
        translationMethod = .mlx
        translationStatus = translator.isLoaded
            ? "第二字幕：\(srcName) → \(tgtName) · Qwen 模型翻譯（已載入）"
            : "第二字幕：\(srcName) → \(tgtName) · Qwen 模型翻譯（首次翻譯時載入）"
    }

    /// Route one finalized sentence to the active translation backend.
    private func translateSentence(id: UUID, text: String) {
        switch translationMethod {
        case .apple:
            translation.translate(id: id, text: text)
        case .mlx:
            guard let translator = mlxTranslator else { return }
            let target = settings.secondLanguage.modelTargetName   // exactly the selected language
            let srcName = settings.firstLanguage == "auto" ? "自動偵測" : settings.firstLanguage
            let tgtName = settings.secondLanguage.displayName
            Task { [weak self] in
                guard let self else { return }
                // Load the model into memory on first use (already on disk from Start).
                guard await self.ensureQwenReady(translator, srcName: srcName, tgtName: tgtName) else { return }
                guard let translated = await translator.translate(text, target: target) else { return }
                self.applyTranslation(id: id, chinese: translated)
            }
        case .none:
            break
        }
    }

    // MARK: - ASR events

    private func handle(_ event: TranscriptEvent) {
        switch event {
        case .interim(let text, _, _):
            // Live partial of the sentence being spoken right now.
            interimText = text
            // A new sentence started after a finalize → drop the stale interim
            // translation.
            if currentOverlayId != nil { interimChinese = "" }
            currentOverlayId = nil
            syncOverlay()
            scheduleInterimTranslation(text)
        case .finalized(let segment):
            let english = cleaner.cleanup(segment.text)
            guard !english.isEmpty else { return }
            // Stop live-translating; the accurate finalized translation takes over.
            interimThrottleTask?.cancel(); interimThrottleTask = nil
            currentInterimId = nil
            pendingInterimText = nil
            interimInFlight = false

            interimText = ""
            interimChinese = ""

            // Split a (possibly multi-sentence) utterance into individual
            // sentences, so captions appear one sentence at a time — not one
            // big block — in both the list and the overlay.
            let sentences = Self.splitSentences(english)
            var lastId: UUID?
            for sentence in sentences {
                let id = UUID()
                lastId = id
                lines.append(CaptionLine(id: id, english: sentence, chinese: nil))
                let seg = TranscriptSegment(
                    id: id,
                    sessionId: currentSessionId,
                    index: segmentIndex,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    source: segment.source,
                    speakerLabel: segment.speakerLabel,
                    sourceText: sentence
                )
                segmentIndex += 1
                store.append(seg)
                // Translate via the active backend (Apple or Qwen/MLX).
                translateSentence(id: id, text: sentence)
            }
            if lines.count > 500 { lines.removeFirst(lines.count - 500) }
            currentOverlayId = lastId   // marks that a sentence just finalized
            syncOverlay()
        }
    }

    /// Mirror the latest lines + interim into the floating overlay box.
    private func syncOverlay() {
        overlay.model.lines = Array(lines.suffix(10))
        overlay.model.interimEnglish = interimText
        overlay.model.interimChinese = interimChinese
    }

    private func applyTranslation(id: UUID, chinese: String) {
        // Live (interim) translation for the sentence still being spoken.
        if id == currentInterimId, currentOverlayId == nil {
            interimChinese = chinese
            interimInFlight = false
            syncOverlay()
            tryFireInterim()   // send the next pending interim, if any
            return
        }
        // A late interim result that arrived after the sentence finalized.
        if id == currentInterimId {
            interimInFlight = false
        }
        // Finalized line translation.
        if let i = lines.firstIndex(where: { $0.id == id }) {
            lines[i].chinese = chinese
        }
        store.updateTranslation(segmentId: id, translated: chinese)
        syncOverlay()
    }

    /// Translate the in-progress (interim) sentence so the second caption updates
    /// in real time. Throttled (≤ one per `interimTranslateInterval`) AND limited
    /// to a single request in flight, so a finalized sentence's accurate
    /// translation is never stuck behind a backlog of interim ones.
    private func scheduleInterimTranslation(_ text: String) {
        // Live interim translation is Apple-only (the model is too slow per word).
        guard translationMethod == .apple, settings.needsTranslation else { return }
        pendingInterimText = text
        tryFireInterim()
    }

    private func tryFireInterim() {
        guard !interimInFlight, currentOverlayId == nil, let text = pendingInterimText else { return }
        let elapsed = Date().timeIntervalSince(lastInterimTranslateAt)
        if elapsed >= interimTranslateInterval {
            fireInterim(text)
        } else if interimThrottleTask == nil {
            let delay = interimTranslateInterval - elapsed
            interimThrottleTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.interimThrottleTask = nil
                self.tryFireInterim()
            }
        }
    }

    private func fireInterim(_ text: String) {
        pendingInterimText = nil
        interimInFlight = true
        lastInterimTranslateAt = Date()
        let id = UUID()
        currentInterimId = id
        translation.translate(id: id, text: text)
    }

    /// Split text into sentences, keeping terminal punctuation. Used so the
    /// transcript and overlay present one sentence at a time.
    static func splitSentences(_ text: String) -> [String] {
        let terminators: Set<Character> = [".", "?", "!", "。", "！", "？", "…"]
        var sentences: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if terminators.contains(ch) {
                let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { sentences.append(s) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences.isEmpty ? [text] : sentences
    }

    /// Clear all live-caption / live-translation bookkeeping.
    private func resetLiveCaptionState() {
        currentOverlayId = nil
        currentInterimId = nil
        pendingInterimText = nil
        interimThrottleTask?.cancel()
        interimThrottleTask = nil
        interimInFlight = false
        lastInterimTranslateAt = .distantPast
        interimChinese = ""
    }

    // MARK: - Recognition / meeting lifecycle

    func startRecognition() async {
        guard asrState == .idle else { return }
        asrState = .loading
        statusMessage = "Loading Nemotron model (first run downloads it)…"
        do {
            // Start the Qwen download now (in parallel with the ASR model download),
            // both triggered by the "Start meeting" button.
            prefetchQwen()
            // Apply the selected first-caption language before loading the model.
            asr.currentLanguage = settings.firstLanguage
            asr.onLoadProgress = { [weak self] p in
                Task { @MainActor in self?.statusMessage = "Loading model… \(Int(p * 100))%" }
            }
            try await asr.loadModels(tier: settings.asrTier)
            try await asr.startStream()
            currentSession = store.beginSession(settings: settings)
            segmentIndex = 0
            lines.removeAll()
            summaryText = ""
            lastSummaryEN = nil
            lastSummaryZH = nil
            interimText = ""
            resetLiveCaptionState()
            overlay.model.clear()
            asrState = .listening
            statusMessage = "Listening — enable a source to start"
        } catch {
            asrState = .idle
            statusMessage = "ASR load failed: \(error)"
        }
    }

    func endMeeting() async {
        asr.stopStream()
        asr.releaseModels()       // free ASR memory before loading the summary LLM (MLX)
        unloadQwen()              // free the live translator's model too
        store.endSession()
        asrState = .idle
        interimText = ""
        interimChinese = ""
        resetLiveCaptionState()
        overlay.model.clear()
        statusMessage = "Meeting ended, generating summary…"
        await summarize()
        statusMessage = "Meeting ended"
    }

    private func summarize() async {
        guard let session = currentSession else { return }
        isSummarizing = true
        defer { isSummarizing = false }

        var pair: (english: Summary, chinese: Summary)?
        do {
            // Make sure the at-Start disk prefetch finished so the summarizer loads
            // from cache instead of starting its own concurrent download.
            await qwenPrefetchTask?.value
            statusMessage = "Generating summary with MLX (Qwen3-1.7B, thinking)…"
            pair = try await mlxSummarizer.summarizeBilingual(session: session, segments: store.segments) { p in
                Task { @MainActor in self.statusMessage = "Summarizing… \(Int(p * 100))%" }
            }
        } catch {
            // MLX unavailable (offline / first-run download failed / low memory):
            // fall back to the on-device extractive summary so the user still gets one.
            Self.log.error("Qwen summary failed: \(String(reflecting: error), privacy: .public)")
            modelStatus = "Qwen 摘要載入失敗：\(String(describing: error))"
            statusMessage = "MLX summary unavailable, using extractive fallback…"
            pair = try? await fallbackSummarizer.summarizeBilingual(session: session, segments: store.segments, progress: nil)
        }

        guard let pair else { return }
        lastSummaryEN = pair.english
        lastSummaryZH = pair.chinese
        // Show English and Traditional Chinese as separate sections.
        summaryText = "🇬🇧 English\n" + Self.renderSummary(pair.english)
            + "\n\n🇹🇼 繁體中文\n" + Self.renderSummary(pair.chinese)
    }

    /// Render a single-language summary as a readable text block.
    private static func renderSummary(_ s: Summary) -> String {
        var text = s.overview
        if !s.keyPoints.isEmpty {
            text += "\n\n• " + s.keyPoints.joined(separator: "\n• ")
        }
        if !s.decisions.isEmpty {
            text += "\n\nDecisions / 決議:\n• " + s.decisions.joined(separator: "\n• ")
        }
        if !s.actionItems.isEmpty {
            text += "\n\nAction Items / 待辦:\n• " + s.actionItems.map(\.text).joined(separator: "\n• ")
        }
        if !s.qa.isEmpty {
            text += "\n\nQ&A:\n" + s.qa.map { "• Q: \($0.question)\n  A: \($0.answer)" }.joined(separator: "\n")
        }
        return text
    }

    // MARK: - Overlay

    func toggleOverlay() {
        overlayOn.toggle()
        if overlayOn { overlay.show() } else { overlay.hide() }
    }

    // MARK: - Export

    func exportTranscript() {
        guard let session = currentSession else { return }
        let exporter = TranscriptExporter()
        guard let data = try? exporter.exportBilingual(
            session: session, segments: store.segments,
            chinese: lastSummaryZH, english: lastSummaryEN, format: .markdown
        ) else {
            statusMessage = "Nothing to export"
            return
        }

        // Let the user choose where to save (NSSavePanel), defaulting to a
        // timestamped Markdown file.
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "FlowTranslate-\(Int(Date().timeIntervalSince1970)).md"
        panel.canCreateDirectories = true
        panel.title = "匯出逐字稿 Export transcript"
        if let md = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [md]
        }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url)
                self?.statusMessage = "Exported transcript to \(url.path)"
            } catch {
                self?.statusMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Audio sources

    func toggleMic() async {
        if micEnabled {
            router.disable(.microphone); micEnabled = false; micLevel = 0
            return
        }
        // If permission was previously denied, requestAccess won't prompt again —
        // guide the user to System Settings instead.
        switch Permissions.microphoneStatus {
        case .denied, .restricted:
            statusMessage = "麥克風權限被拒。請到系統設定 > 隱私權與安全性 > 麥克風 開啟 Flow Translate"
            Permissions.openMicrophoneSettings()
            return
        default:
            break
        }
        guard await Permissions.requestMicrophone() else {
            statusMessage = "麥克風權限被拒"; Permissions.openMicrophoneSettings(); return
        }
        do {
            try await router.enable(.microphone); micEnabled = true
            statusMessage = "麥克風已開啟"
        } catch {
            statusMessage = "麥克風啟動失敗: \(error.localizedDescription)"
        }
    }

    func toggleSystem() async {
        if systemEnabled {
            router.disable(.system); systemEnabled = false; systemSourceOn = false; systemLevel = 0
        } else {
            guard await Permissions.requestScreenRecording() else {
                statusMessage = "Screen Recording permission needed (System Settings > Privacy)"; return
            }
            do { try await router.enable(.system); systemEnabled = true; systemSourceOn = true }
            catch { statusMessage = "Failed to start system audio: \(error)" }
        }
    }

    private func updateLevel(_ source: AudioSourceType, _ rms: Float) {
        switch source {
        case .microphone: micLevel = rms
        case .system: systemLevel = rms
        }
    }

    // MARK: - Session bookkeeping

    private var currentSession: Session?
    private var currentSessionId: UUID { currentSession?.id ?? UUID() }
}
