import Foundation
import FlowTranslateCore

/// Runs the eval corpus through the **real** model and scores it.
///
/// The unit tests grade the deterministic floor — salvage, optimize, compress,
/// render — with no model at all. That number says whether the Swift half is
/// sound; it says nothing about whether Qwen actually extracts intent well, and
/// that is the half the feature was accused of being weak at. Same corpus, same
/// scorer, so the two scorecards sit side by side and the difference is exactly
/// the model's contribution.
///
/// Holds no model of its own: it drives the same `QwenPromptCompiler` the Prompt
/// tab uses, against the same shared host.
@MainActor
final class PromptEvalRunner: ObservableObject {

    struct Progress: Equatable {
        var done: Int
        var total: Int
        var currentCase: String
    }

    /// Heuristic versus real-tokenizer counts over the corpus, so the estimate's
    /// accuracy is a measured number rather than a claim. The eval already has
    /// the model loaded; counting the same strings twice costs nothing extra.
    @Published private(set) var tokenAccuracy: String = ""

    @Published private(set) var progress: Progress?
    @Published private(set) var report: PromptEvalReport?
    @Published private(set) var statusMessage: String = ""

    var isRunning: Bool { progress != nil }

    private let compiler: QwenPromptCompiler
    private let qwenHost: QwenModelHost
    /// Names what is holding the shared models, or nil when nothing is.
    private let blockedBy: @MainActor () -> String?
    private let settingsProvider: @MainActor () -> CaptionSettings
    private let rulebookProvider: @MainActor () -> PromptRulebook
    private let didFinishWork: @MainActor () -> Void
    /// Loads the shared model through the owner, inheriting its failure budget,
    /// its single load task and its wait on the at-Start prefetch.
    private let prepareModel: (@MainActor () async -> String?)?
    private var work: Task<Void, Never>?

    init(
        qwenHost: QwenModelHost,
        blockedBy: @escaping @MainActor () -> String?,
        settings: @escaping @MainActor () -> CaptionSettings,
        rulebook: @escaping @MainActor () -> PromptRulebook,
        didFinishWork: @escaping @MainActor () -> Void = {},
        prepareModel: (@MainActor () async -> String?)? = nil
    ) {
        self.prepareModel = prepareModel
        self.compiler = QwenPromptCompiler(host: qwenHost)
        self.qwenHost = qwenHost
        self.blockedBy = blockedBy
        self.settingsProvider = settings
        self.rulebookProvider = rulebook
        self.didFinishWork = didFinishWork
    }

    /// Score every case, or a named subset.
    ///
    /// Each case is one full compile, so the whole corpus is 22 generations —
    /// minutes, not seconds, on an M1 Pro. Progress is reported per case and the
    /// run is cancellable, because a diagnostic that cannot be stopped is one
    /// nobody runs twice.
    func run(cases: [PromptEvalCase] = PromptEvalCases.all) {
        guard !isRunning else { return }
        guard blockedBy() == nil else {
            statusMessage = "模型使用中，請先停止其他工作 Models are busy"
            return
        }
        progress = Progress(done: 0, total: cases.count, currentCase: "")
        report = nil
        statusMessage = ""
        work = Task { [weak self] in await self?.execute(cases) }
    }

    func cancel() {
        work?.cancel()
    }

    /// Cancel and wait. Called before the shared model is unloaded — a
    /// generation still on the GPU when `unload()` clears the MLX cache is the
    /// crash the rest of this app is written to avoid.
    func cancelAndDrain() async {
        work?.cancel()
        await work?.value
        work = nil
        progress = nil
    }

    private func execute(_ cases: [PromptEvalCase]) async {
        let settings = settingsProvider()
        let rulebook = rulebookProvider()
        // Read once, up front. Omitting this made `effectiveMode` downgrade every
        // case to the written-out mode, so the run measured a rendering the user never
        // sees while the scorecard header still claimed the requested mode — the
        // one thing `pasteableReport` exists to prevent.
        let syncedSymbols = settings.promptTargetProjectPath
            .map { PromptArtifactWriter.allSyncedSymbols(inProjectAt: $0) } ?? []
        var results: [PromptEvalResult] = []
        var estimated = 0
        var measured = 0

        for (index, evalCase) in cases.enumerated() {
            if Task.isCancelled { break }
            progress = Progress(done: index, total: cases.count, currentCase: evalCase.id)

            let outcome = await compiler.compile(
                request: evalCase.input,
                language: evalCase.language,
                rulebook: rulebook,
                symbolMode: settings.promptSymbolMode,
                // Settings is reachable without ever opening the Prompt tab, so
                // this can be the first thing that needs the model. Without the
                // callback the run would sit on "0/22" through a 2.3 GB
                // download, indistinguishable from a hang.
                onDownload: { [weak self] fraction in
                    Task { @MainActor in
                        self?.statusMessage = "下載模型 Downloading model \(Int(fraction * 100))%"
                    }
                },
                prepareModel: prepareModel
            )
            if !statusMessage.hasPrefix("模型無法使用") { statusMessage = "" }
            if Task.isCancelled { break }

            // A case the model never got to is not a case the model failed.
            // Recording it as a zero would blame Qwen for a missing download.
            if case let .modelUnavailable(reason) = outcome.outcome {
                statusMessage = "模型無法使用，已中止 Model unavailable: \(reason)"
                break
            }

            // `optimize`, deliberately not `autoFix` — even though the Prompt tab
            // runs both. `autoFix` adds the default scope exclusion ("… no
            // unrelated refactors …") to any IR that has none, and that sentence
            // contains a negation. Every prompt would then read as a prohibition,
            // and the negation check — the one measurement here that catches an
            // inverted meaning — would pass unconditionally. The eval measures the
            // model's own output; the tab's extra pass is not part of it.
            let optimized = PromptOptimizer.optimize(
                outcome.ir,
                repoRoot: settings.promptTargetProjectPath,
                request: evalCase.input
            )
            let rendered = PromptRenderer.render(
                optimized,
                options: PromptRenderOptions(
                    kind: .prompt,
                    language: evalCase.language,
                    symbolMode: settings.promptSymbolMode,
                    rulebook: rulebook,
                    syncedSymbols: syncedSymbols,
                    layout: settings.promptLayout,
                    detail: settings.promptDetailLevel
                )
            )
            // `salvaged` means the model ran and returned nothing parseable.
            // That IS a model failure and is scored as one, which is why the
            // compiler distinguishes it from `modelUnavailable`.
            results.append(
                PromptEvalScorer.score(evalCase, ir: optimized, rendered: rendered.content)
            )
            if let exact = await qwenHost.countTokens(rendered.content) {
                estimated += TokenEstimator.estimate(rendered.content)
                measured += exact
            }
        }

        progress = nil
        if measured > 0 {
            let drift = Double(estimated - measured) / Double(measured) * 100
            tokenAccuracy = String(
                format: "字元估算 %d vs Qwen 實際分詞 %d — 估算偏差 %+.1f%%",
                estimated, measured, drift
            ) + "\n" + (await calibrationProbe() ?? "")
        }
        if !results.isEmpty {
            report = PromptEvalReport(results: results)
            if results.count < cases.count, statusMessage.isEmpty {
                statusMessage = "已取消，僅計入 \(results.count)/\(cases.count) 題 Cancelled"
            }
        }
        didFinishWork()
    }

    /// Measure chars-per-token per script class against the real tokenizer.
    ///
    /// The corpus-wide drift says the heuristic is off but not *where*, and
    /// scaling every constant by the aggregate would fit one corpus rather than
    /// the tokenizer. These probes measure each class `TokenEstimator` calibrates
    /// separately, so the constants can be set from a number instead of a guess.
    private func calibrationProbe() async -> String? {
        // Each probe is **pure**: it contains its own class and nothing else
        // except the spaces the tokenizer needs to see word boundaries — which
        // `TokenEstimator` charges nothing for, and which are excluded from the
        // denominator below.
        //
        // Purity is the whole point of the measurement. A mixed probe — a "digit"
        // probe containing `0x1F4`, a "symbol" probe that is 70% Latin letters —
        // divided by `text.count` calibrates nothing: the "symbol" reading of
        // 3.48 would mostly be a measurement of
        // English prose.
        let probes: [(String, String, Double)] = [
            ("latin", String(repeating:
                "the uploader retries transient failures in RetryPolicy before "
                + "UploaderTests surfaces maxRetryCount to the caller ", count: 8),
             TokenEstimator.latinCharsPerToken),
            ("cjk", String(repeating:
                "請在上傳失敗時以指數退避重試並且不要新增任何第三方套件", count: 12),
             TokenEstimator.cjkCharsPerToken),
            ("digit", String(repeating: "17492026080465536123456784015031000", count: 10),
             TokenEstimator.digitCharsPerToken),
            ("symbol", String(repeating: "</>{[()]}=>!=<=++--::&&||~^#@", count: 12),
             TokenEstimator.symbolCharsPerToken),
        ]
        var parts: [String] = []
        for (name, text, assumed) in probes {
            guard let real = await qwenHost.countTokens(text), real > 0 else { return nil }
            // Only the class's own characters count against its ratio. Whitespace
            // is excluded because the estimator charges nothing for it — a
            // leading space is folded into the token that follows.
            let ownCharacters = text.count { !$0.isWhitespace }
            let measuredRatio = Double(ownCharacters) / Double(real)
            parts.append(String(format: "%@ %.2f (現用 %.2f)", name, measuredRatio, assumed))
        }
        // A pure-class probe reads *above* its constant on purpose. The constants
        // are a least-squares fit over whole prompts, where each class is
        // surrounded by punctuation and the other scripts; isolated prose
        // tokenizes more efficiently than the same prose inside a prompt. The
        // line above — total estimate against total measurement — is the number
        // to judge the calibration by; these four say which class moved.
        return "每類實測字元/token（單一類別上限，常數是混合文本擬合值）— "
            + parts.joined(separator: "，")
    }

    /// The scorecard plus the conditions it was measured under.
    ///
    /// A bare score is not reproducible: the same corpus scores differently at a
    /// different compression profile, symbol mode or target agent, so the
    /// settings travel with the number.
    var pasteableReport: String? {
        guard let report else { return nil }
        let settings = settingsProvider()
        return """
        Prompt Composer eval — live model
        agent: \(settings.promptLayout.rawValue)  \
        symbols: \(settings.promptSymbolMode.rawValue)  \
        detail: \(settings.promptDetailLevel.rawValue)

        \(report.summary)
        \(tokenAccuracy.isEmpty ? "" : "\n" + tokenAccuracy)
        """
    }
}
