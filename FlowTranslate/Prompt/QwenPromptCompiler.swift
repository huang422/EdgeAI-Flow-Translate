import Foundation
import FlowTranslateCore

/// Turns a spoken or typed request into a `PromptIR` — the one stage of the
/// prompt pipeline that needs a language model.
///
/// Everything downstream (optimization, symbolic compression, lint, all four
/// output backends) is deterministic Swift in `FlowTranslateCore`. Confining the
/// model to a single structured-extraction call is what makes the rest testable,
/// and it is also the performance decision: on an M1 Pro the bottleneck is
/// decode, and an IR of bullet fragments is far shorter than the finished prompt
/// it will be rendered into.
///
/// Holds no model of its own — it reuses the single `QwenModelHost` shared with
/// live translation, transcript correction and the meeting summarizer, so this
/// feature adds no resident model memory at all.
final class QwenPromptCompiler {
    private let host: QwenModelHost

    init(host: QwenModelHost) { self.host = host }

    /// Why a compile ended the way it did.
    ///
    /// These were previously collapsed into one "salvaged" flag, which reported
    /// "you are offline / the 2.3 GB download failed" to the user as "the
    /// model's output was unparseable" — two completely different problems with
    /// completely different fixes.
    enum Outcome: Sendable, Equatable {
        /// The model ran and produced a usable IR.
        case compiled
        /// The model ran, but nothing it returned parsed. The IR was rebuilt
        /// from the raw request.
        case salvaged
        /// Generation stopped mid-object because it hit the token budget, and
        /// not even the completed part could be recovered. The IR was rebuilt
        /// from the raw request: nothing was lost, but the structure was, and the
        /// cause is a budget rather than the model.
        case truncated
        /// Generation stopped mid-object, but everything written before the cut
        /// was recovered. Only the field in progress is missing — usually the
        /// last bullet of the last section.
        case recovered
        /// The model never ran. The IR was rebuilt from the raw request.
        case modelUnavailable(reason: String)
    }

    struct Result: Sendable {
        var ir: PromptIR
        var outcome: Outcome
    }

    /// Compile one request. Never throws: even a failed model yields a thin,
    /// editable IR rather than a dead end — but `outcome` always says which
    /// happened.
    ///
    /// `onProgress` receives generated-token counts from the model's execution
    /// context; `onDownload` receives 0…1 while model files are fetched. Both
    /// arrive off the MainActor — hop before touching UI.
    func compile(
        request: String,
        language: PromptOutputLanguage,
        rulebook: PromptRulebook,
        symbolMode: PromptSymbolMode = .symbolsAssumeRulebook,
        onDownload: (@Sendable (Double) -> Void)? = nil,
        onProgress: (@Sendable (Int) -> Void)? = nil,
        prepareModel: (@MainActor () async -> String?)? = nil
    ) async -> Result {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Result(ir: PromptIR(), outcome: .compiled) }

        // Nothing to restructure. A request of two or three words is already a
        // goal, and running it through the model can only paraphrase it: "Ship
        // it" came back as a goal that no longer contained the word "ship",
        // which is the one word the user said. Below the floor the request is
        // the goal, verbatim — no latency, no drift.
        if Self.isTooShortToRestructure(trimmed) {
            return Result(ir: PromptIRParser.salvage(from: trimmed), outcome: .compiled)
        }

        // Load explicitly rather than letting `generate` do it silently. Without
        // this the first compile on a fresh install spends minutes downloading
        // with the UI stuck on "Compiling…", indistinguishable from a hang.
        if !host.isComplete, await !NetworkCheck.isOnline() {
            return Result(
                ir: PromptIRParser.salvage(from: trimmed),
                outcome: .modelUnavailable(
                    reason: "目前離線，且 Qwen 模型尚未下載（約 2.3 GB）Offline and the model is not downloaded"
                )
            )
        }
        // Load through the owner when it offers a path, so the prompt features
        // inherit everything the caption side already has: the consecutive
        // failure budget that stops a broken install being retried on every
        // compile, the single shared load task, and the wait on the at-Start
        // disk prefetch that keeps one download from becoming two.
        //
        // Calling `host.ensureLoaded` directly — as this did — bypassed all
        // three. A compile during a meeting's prefetch downloaded the same
        // 2.3 GB a second time into the same directory.
        if let prepareModel {
            if let failure = await prepareModel() {
                return Result(
                    ir: PromptIRParser.salvage(from: trimmed),
                    outcome: .modelUnavailable(reason: failure)
                )
            }
        } else {
            do {
                try await host.ensureLoaded(progress: onDownload)
            } catch {
                return Result(
                    ir: PromptIRParser.salvage(from: trimmed),
                    outcome: .modelUnavailable(reason: error.localizedDescription)
                )
            }
        }

        let resolved = language.resolved(for: trimmed)
        let system = Self.systemPrompt(language: resolved, rulebook: rulebook, symbolMode: symbolMode)
        let cap = Self.tokenCap(for: trimmed)

        // `shouldStop` on both branches. Without it a cancelled compile kept
        // decoding to the full cap — up to 1,600 tokens — and every caller that
        // cancels then *awaits* the task paid for all of it: pressing Start on a
        // meeting ran `drainPromptWorkloads()` first, so the meeting sat waiting
        // tens of seconds for a generation whose result was already discarded.
        // `PromptTextRepairer` has always passed this; the compiler, which
        // generates the most tokens of the three, did not.
        let raw: String?
        if let onProgress {
            raw = await host.generateStreaming(
                system: system, user: Self.userPrompt(trimmed), maxTokens: cap,
                temperature: 0.15, topP: 0.9, repetitionPenalty: 1.05,
                shouldStop: { Task.isCancelled },
                onProgress: onProgress
            )
        } else {
            raw = await host.generate(
                system: system, user: Self.userPrompt(trimmed), maxTokens: cap,
                temperature: 0.15, topP: 0.9, repetitionPenalty: 1.05,
                shouldStop: { Task.isCancelled }
            )
        }

        guard let raw else {
            return Result(
                ir: PromptIRParser.salvage(from: trimmed),
                outcome: .modelUnavailable(reason: "模型生成失敗 Generation failed")
            )
        }
        if let parsed = PromptIRParser.parse(raw) {
            return Result(ir: Self.classified(parsed, from: trimmed), outcome: .compiled)
        }
        // A run that hit the cap left an object that never closed. Keep the part
        // that did arrive rather than discarding a whole generation because of
        // its last half-written field.
        if PromptIRParser.looksTruncated(raw) {
            if let recovered = PromptIRParser.recoverTruncated(raw) {
                return Result(ir: Self.classified(recovered, from: trimmed), outcome: .recovered)
            }
            return Result(
                ir: Self.classified(PromptIRParser.salvage(from: trimmed), from: trimmed),
                outcome: .truncated
            )
        }
        return Result(
            ir: Self.classified(PromptIRParser.salvage(from: trimmed), from: trimmed),
            outcome: .salvaged
        )
    }

    /// Delegates to `PromptIRParser.classifying`, which lives in the core
    /// library so the rule can be tested — this target is not reachable from the
    /// test bundle, and the classification is the one step whose failure inverts
    /// a prompt's meaning rather than degrading it.
    static func classified(_ ir: PromptIR, from request: String) -> PromptIR {
        PromptIRParser.classifying(ir, from: request)
    }

    /// Whether a request is short enough that compiling it can only lose.
    ///
    /// Deliberately a very low floor. "Add a retry to Uploader.swift" is five
    /// words and genuinely benefits from being compiled — it has a file, an
    /// implied scope boundary and an acceptance criterion the model can surface.
    /// "Ship it" has none of those, and the only thing a compile can do to it is
    /// choose different words.
    ///
    /// Counted per script, because three words of Chinese is a different amount
    /// of request from three words of English: CJK has no word spaces, so it is
    /// measured in characters instead.
    static func isTooShortToRestructure(_ text: String) -> Bool {
        if TokenEstimator.isCJKDominant(text) {
            return text.count { !$0.isWhitespace } <= 6
        }
        return text.split(whereSeparator: \.isWhitespace).count <= 3
    }

    /// Decode cap for one request.
    ///
    /// Driven by the *number of separate requirements*, not the character count:
    /// "改成 X，讓使用者選 Y，最後測試要過" is three constraints, three acceptance
    /// items and a goal in barely a line, while a rambling paragraph asking for
    /// one thing needs almost nothing. Scaling on length gave the dense request
    /// the smaller budget — exactly backwards.
    ///
    /// **One pass, not two.** A second compile runs without the first half's
    /// context, so the goal is restated twice and the scope boundary inferred
    /// from half the evidence. The ceiling is therefore set where a maximal
    /// request still fits: ~1,200 tokens for the widest IR the schema can produce
    /// (CJK costs about one token per character; see `TokenEstimator`).
    ///
    /// Raising it is cheap — generation stops at EOS, so the cap only bounds a
    /// *runaway*, and `recoverTruncated` keeps whatever was written before a cut.
    static func tokenCap(for text: String) -> Int {
        let byLength = SpokenTextMetrics.units(text) * 4
        let byRequirements = 160 + requirementCount(text) * 80
        return min(1600, max(160, max(byLength, byRequirements)))
    }

    /// How many separate things the request asks for.
    ///
    /// Counts clause boundaries rather than parsing: every comma, semicolon and
    /// full stop in either script, plus the enumerating words that introduce a
    /// further requirement. Approximate on purpose — it only needs to be right
    /// about "one thing" versus "several".
    static func requirementCount(_ text: String) -> Int {
        let separators: Set<Character> = [
            ",", ";", ".", "，", "、", "；", "。", "\n",
        ]
        var count = text.reduce(into: 0) { total, character in
            if separators.contains(character) { total += 1 }
        }
        let connectives = ["並且", "而且", "還要", "然後", "最後", "另外", "同時", "以及",
                           " and ", " also ", " then ", " finally ", " plus "]
        let lowered = text.lowercased()
        for connective in connectives where lowered.contains(connective.lowercased()) {
            count += 1
        }
        return min(12, count)
    }

    // MARK: - Prompts

    /// Kept tight on purpose: this is re-prefilled on every compile, and prefill
    /// is the fixed cost of the call. The symbol catalogue carries only
    /// `SYMBOL — expansion`; the aliases stay on the Swift side, where
    /// `SymbolCompressor` uses them as a deterministic backstop for free.
    /// The catalogue is omitted entirely when symbols are switched off — both to
    /// save prefill and because the renderer would not expand a bare symbol in
    /// that mode, so asking for one produced an unresolvable prompt.
    static func systemPrompt(
        language: PromptOutputLanguage,
        rulebook: PromptRulebook,
        symbolMode: PromptSymbolMode = .symbolsAssumeRulebook
    ) -> String {
        var prompt = """
        You turn a software request into one strict JSON object. Output ONLY that object — no prose, no code fence.

        Schema (omit any field you have nothing for):
        {"taskType":"new|refine|port|debug","goal":"","question":"","steps":[],"context":[],"constraints":[],\
        "scopeExclusions":[],"deliverables":[],"acceptance":[],"failureCases":[],\
        "references":[{"path":"","loadMode":"referenced"}],"suggestedTools":[]}

        Rules:
        - \(languageRule(language))
        - Keep identifiers, file names, paths, commands and technical terms exactly as given. Never translate them.
        - "question" is what the request ASKS — for an explanation, a comparison, a \
        recommendation, or where something should go. Copy it as a question. Never rewrite a \
        question into an instruction to build or change something.
        - "goal" and "question" are INDEPENDENT. A request may ask something, ask for work, or \
        both. Fill in whichever it contains and leave the other out. Never move one into the other.
        - When there is a question, "acceptance" is what a good ANSWER must contain.
        - "goal" is one imperative sentence, verb first, stating the outcome — not the steps.
        - "steps" holds the separate pieces of work IN ORDER, one item each, when the request \
        asks for more than one thing. Leave it out for a single-part request. The goal stays the \
        one-line summary; the steps carry the rest so none of them is lost.
        - An instruction about HOW to work — search the web first, read the existing code before \
        proposing, explain the plan before coding, report every finding — is a "constraint", not a \
        "goal" and not a "step". "steps" and "goal" are the work itself. This matters: a directive \
        filed as a step cannot be recognised as a rule, so "先上網搜尋最佳做法" stayed a sentence \
        instead of becoming WEB_SEARCH however often it was asked for.
        - Every list item is a short imperative fragment, never a paragraph.
        - "scopeExclusions" is what the request SAYS must not change. Only when it says so — \
        do not infer a boundary the request does not state.
        - "acceptance" must be checkable — a command that passes, a file that exists. Never "works well".
        - "references" are ONLY files the request itself names. Never copy a path from the examples \
        below, and never invent one — if the request names no file, omit "references" entirely. \
        Use loadMode "referenced" so the reader opens the file itself; never paste file contents.
        - Add nothing the request does not contain. Leave a field out rather than inventing it.
        - A constraint the request does not state is an invented constraint. Do not add \
        NO_DEPS, TEST_PASS or any other rule just because it is common — only when the request \
        actually says it. Many requests have no constraints at all; "constraints" is then absent.
        - Cover EVERY requirement in the request, including ones stated at the very end. A request \
        joined by commas or by words like "最後", "還要", "and also" contains several separate \
        requirements — emit one list item for each. Losing the last one is the most common failure; \
        re-read the request to the end before you finish.
        """

        // Omitted entirely for "keep my wording". The catalogue tells the model
        // to answer with `NO_DEPS` instead of the sentence, and the renderer then
        // expands that back into the rulebook's phrasing — so the one mode that
        // promises to preserve what you wrote was the one guaranteed to lose it.
        // Skipping the catalogue also saves the prefill.
        if symbolMode != .off, !rulebook.rules.isEmpty {
            let catalogue = rulebook.rules
                .map { "\($0.symbol) — \($0.description)" }
                .joined(separator: "\n")
            prompt += """


            If a constraint, exclusion or acceptance item means the same as one of these rules, output the \
            SYMBOL alone instead of the sentence:
            \(catalogue)
            """
        }
        prompt += "\n\n" + examples(language: language)
        return prompt
    }

    /// Two worked examples, which is the difference between a 4B model that
    /// mostly emits the schema and one that reliably does.
    ///
    /// Rules alone are not enough: without these the model returns prose around
    /// the JSON, splits identifiers on their dots, drops `scopeExclusions`, and
    /// answers a Chinese request in Chinese regardless of the language rule. Each
    /// example is chosen for what it demonstrates rather than for coverage, since
    /// every token here is paid on every compile:
    ///
    /// - The first is English and shows a path surviving verbatim, a constraint
    ///   collapsing to a symbol, and — since the request names no boundary —
    ///   `scopeExclusions` left out entirely.
    /// - The second is a Chinese request with an English answer, which is the
    ///   rule the model breaks most often, and shows a code-switched identifier
    ///   (`uploadChunk`) left alone rather than translated, plus the *stated*
    ///   prohibition going where the rule says it goes.
    ///
    /// Neither example may infer an exclusion the request never made: an example
    /// teaching the model to file an inference in `out_of_scope` teaches it to
    /// lose a real prohibition there.
    ///
    /// The model always emits symbols; the renderer decides whether they survive
    /// into the output or are written out. That split keeps the examples
    /// independent of any display setting.
    static func examples(language: PromptOutputLanguage) -> String {
        let noDeps = "NO_DEPS"
        let testPass = "TEST_PASS"
        let keepAPI = "KEEP_API"

        if language == .traditionalChinese {
            return """
            Example 1 — the request states no boundary, so "scopeExclusions" is absent.
            Request: So um I was wondering if you could add a retry with exponential backoff to the \
            uploader in Sources/Uploader.swift, it fails on transient 5xx errors. Don't add new dependencies.
            {"taskType":"refine","goal":"為上傳器加入指數退避重試","context":["Sources/Uploader.swift 遇到暫時性 5xx 即失敗"],\
            "constraints":["\(noDeps)"],\
            "references":[{"path":"Sources/Uploader.swift","loadMode":"referenced"}],\
            "acceptance":["暫時性 5xx 會重試而非直接失敗"]}

            Example 2 — "不要動到 public API" is a stated boundary, so it goes in "scopeExclusions".
            Request: 幫我 refactor 這個 uploadChunk function，不要動到 public API，然後測試要過。
            {"taskType":"refine","goal":"重構 uploadChunk 而不改變其行為","constraints":["\(testPass)"],\
            "scopeExclusions":["\(keepAPI)"],"acceptance":["現有測試全數通過"]}

            Example 3 — the request states no constraints, so there are none.
            Request: parser 在空輸入的時候會 index out of range，第 412 行，看一下為什麼。
            {"taskType":"debug","goal":"找出 parser 在空輸入時 index out of range 的原因",\
            "context":["第 412 行，輸入為空時發生"]}

            Example 4 — a QUESTION with no work attached, so "goal" is absent.
            Request: 如果我用這個方式，檔案要匯出放在哪裡 rulebook 跟壓縮才有用？
            {"taskType":"new","question":"檔案要匯出到哪裡，rulebook 與壓縮才會生效？",\
            "acceptance":["說明實際路徑與該工具讀取它的時機"]}

            Example 4b — asks AND instructs, so BOTH fields are filled.
            Request: 為何第二字幕會跳動？順便把 finalize 的問題修好。
            {"taskType":"debug","question":"為何第二字幕會跳動？",\
            "goal":"修好 finalize 造成第二字幕跳動的問題"}

            Example 5 — several separate pieces of work, so they go in "steps" in order.
            Request: 改成 XML 標籤輸出，讓使用者選 claude 或 codex，不要新增套件，最後測試要過。
            {"taskType":"refine","goal":"把輸出改成 XML 標籤並加上代理選項",\
            "steps":["改成 XML 標籤輸出","讓使用者選擇 claude 或 codex"],\
            "constraints":["NO_DEPS","TEST_PASS"]}
            """
        }
        return """
        Example 1 — the request states no boundary, so "scopeExclusions" is absent.
        Request: So um I was wondering if you could add a retry with exponential backoff to the \
        uploader in Sources/Uploader.swift, it fails on transient 5xx errors. Don't add new dependencies.
        {"taskType":"refine","goal":"Add exponential-backoff retry to the uploader",\
        "context":["Sources/Uploader.swift fails on transient 5xx"],"constraints":["\(noDeps)"],\
        "references":[{"path":"Sources/Uploader.swift","loadMode":"referenced"}],\
        "acceptance":["Transient 5xx is retried rather than failing"]}

        Example 2 — "不要動到 public API" is a stated boundary, so it goes in "scopeExclusions".
        Request: 幫我 refactor 這個 uploadChunk function，不要動到 public API，然後測試要過。
        {"taskType":"refine","goal":"Refactor uploadChunk without changing its behaviour",\
        "constraints":["\(testPass)"],\
        "scopeExclusions":["\(keepAPI)"],\
        "acceptance":["Existing tests pass"]}

        Example 3 — the request states no constraints, so there are none.
        Request: The parser throws index out of range on empty input, line 412. Find out why.
        {"taskType":"debug","goal":"Find why the parser throws index out of range on empty input",\
        "context":["Line 412, triggered when the input is empty"]}

        Example 4 — a QUESTION with no work attached, so "goal" is absent.
        Request: Where do the exported files have to go for the rulebook and the compression to work?
        {"taskType":"new","question":"Where must the exported files go for the rulebook and \
        compression to take effect?","acceptance":["Names the actual path and when the tool reads it"]}

        Example 4b — asks AND instructs, so BOTH fields are filled.
        Request: Why does the second caption flicker? And fix the finalize bug while you're there.
        {"taskType":"debug","question":"Why does the second caption flicker?",\
        "goal":"Fix the finalize bug behind the second-caption flicker"}

        Example 5 — several separate pieces of work, so they go in "steps" in order.
        Request: Rewrite the renderer to emit XML tags, let the user pick claude or codex, don't \
        add dependencies, and make sure the tests pass.
        {"taskType":"refine","goal":"Rewrite the renderer to emit XML tags with an agent choice",\
        "steps":["Rewrite the renderer to emit XML tags","Let the user pick claude or codex mode"],\
        "constraints":["NO_DEPS","TEST_PASS"]}
        """
    }

    static func languageRule(_ language: PromptOutputLanguage) -> String {
        switch language {
        case .traditionalChinese:
            return "Write every value in Traditional Chinese as used in Taiwan (台灣正體中文). Never use Simplified characters."
        case .english:
            return "Write every value in English, even when the request is in another language."
        }
    }

    static func userPrompt(_ request: String) -> String {
        "Request:\n\(request)"
    }
}
