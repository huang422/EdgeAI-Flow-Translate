import Foundation

/// The graded set. Real requests, in the three shapes this app actually gets:
/// English, Chinese, and code-switched.
///
/// Expectations are necessary conditions, not a golden output — there is no one
/// correct phrasing of a prompt, and asserting on one would measure conformity
/// to whatever the model produced the day the fixture was written.
///
/// Lives in Core rather than the test target because both grade against it: the
/// unit tests measure the deterministic floor with no model, and the in-app
/// runner measures the real thing. Two corpora would make those two numbers
/// incomparable, which is the only reason to have them.
public enum PromptEvalCases {

    public static let all: [PromptEvalCase] = english + chinese + mixed + adversarial

    // MARK: - English

    public static let english: [PromptEvalCase] = [
        PromptEvalCase(
            id: "en-retry",
            input: "So um I was wondering if you could basically add a retry with exponential "
                + "backoff to the uploader in Sources/Uploader.swift, it currently just fails on "
                + "transient 5xx errors. Please don't add any new dependencies.",
            requiredTerms: ["Sources/Uploader.swift", "5xx"],
            goalKeywords: ["retry", "uploader"],
            expectedSymbols: ["NO_DEPS"],
            forbiddenTerms: ["I was wondering", "basically"],
            isNegated: true
        ),
        PromptEvalCase(
            id: "en-migration",
            input: "I need you to write a migration that adds a nullable created_at column to "
                + "the orders table, and make sure the existing tests still pass. Don't change "
                + "the public API of OrderRepository.",
            requiredTerms: ["created_at", "OrderRepository"],
            goalKeywords: ["migration", "orders"],
            expectedSymbols: ["TEST_PASS", "KEEP_API"],
            forbiddenTerms: ["I need you to"],
            isNegated: true
        ),
        PromptEvalCase(
            id: "en-debug",
            input: "The parser throws an index out of range on line 412 when the input is empty. "
                + "Find out why and fix it, but keep the change as small as possible.",
            requiredTerms: ["412"],
            goalKeywords: ["parser", "fix"],
            expectedSymbols: ["MIN_DIFF"],
            forbiddenTerms: []
        ),
        PromptEvalCase(
            id: "en-perf",
            input: "Could you please profile the report generator, it takes about 30 seconds for "
                + "1000 rows which seems really slow. Measure before you change anything.",
            requiredTerms: ["30", "1000"],
            goalKeywords: ["profile", "report"],
            expectedSymbols: ["MEASURE_FIRST"],
            forbiddenTerms: ["Could you please", "really"]
        ),
        PromptEvalCase(
            id: "en-security",
            input: "Move the Stripe API key out of config.js and read it from the environment "
                + "instead. Never commit it.",
            requiredTerms: ["config.js", "Stripe"],
            // `env` rather than `environment`: the synonym map legitimately
            // shortens it, and `env` is a prefix of both forms.
            goalKeywords: ["env"],
            expectedSymbols: ["NO_SECRETS_IN_CODE"],
            forbiddenTerms: [],
            isNegated: true
        ),
        PromptEvalCase(
            id: "en-test",
            input: "Add a unit test for the retry path in UploaderTests.swift. It must not use "
                + "sleep and must not touch the network.",
            requiredTerms: ["UploaderTests.swift"],
            goalKeywords: ["test", "retry"],
            expectedSymbols: ["DETERMINISTIC_TESTS"],
            forbiddenTerms: [],
            isNegated: true
        ),
        PromptEvalCase(
            id: "en-refactor-bounded",
            input: "Extract the duplicated date formatting in ReportBuilder into one helper. "
                + "Do not refactor anything else in that file.",
            requiredTerms: ["ReportBuilder"],
            goalKeywords: ["extract", "date"],
            expectedSymbols: ["NO_REFACTOR"],
            forbiddenTerms: [],
            isNegated: true
        ),
        PromptEvalCase(
            id: "en-git",
            input: "Commit this as a conventional commit and open a PR against main. Branch first, "
                + "don't commit straight to main.",
            requiredTerms: ["main"],
            goalKeywords: ["commit"],
            expectedSymbols: ["CONVENTIONAL_COMMITS", "BRANCH_FIRST"],
            forbiddenTerms: [],
            isNegated: true
        ),
    ]

    // MARK: - Chinese

    public static let chinese: [PromptEvalCase] = [
        PromptEvalCase(
            id: "zh-retry",
            input: "嗯，我想說是不是可以幫我在 Sources/Uploader.swift 加上重試機制，"
                + "現在遇到 5xx 就直接失敗了。不要新增任何套件。",
            requiredTerms: ["Sources/Uploader.swift", "5xx"],
            goalKeywords: ["retry", "uploader"],
            expectedSymbols: ["NO_DEPS"],
            forbiddenTerms: ["我想說"],
            isNegated: true
        ),
        PromptEvalCase(
            id: "zh-api",
            input: "請你幫我重構 OrderRepository 裡面的查詢邏輯，但是不要動到公開的 API，"
                + "而且既有的測試都要通過。",
            requiredTerms: ["OrderRepository"],
            goalKeywords: ["refactor", "quer"],
            expectedSymbols: ["KEEP_API", "TEST_PASS"],
            forbiddenTerms: ["請你幫我"],
            isNegated: true
        ),
        PromptEvalCase(
            id: "zh-perf",
            input: "報表產生器跑 1000 筆要 30 秒，太慢了。麻煩你先量測再最佳化，"
                + "不要一開始就亂改。",
            requiredTerms: ["1000", "30"],
            goalKeywords: ["report", "slow"],
            expectedSymbols: ["MEASURE_FIRST"],
            forbiddenTerms: ["麻煩你"]
        ),
        PromptEvalCase(
            id: "zh-secret",
            input: "把 config.js 裡面的金鑰改成從環境變數讀，不要寫死在程式碼裡。",
            requiredTerms: ["config.js"],
            goalKeywords: ["environment"],
            expectedSymbols: ["NO_SECRETS_IN_CODE"],
            forbiddenTerms: [],
            isNegated: true
        ),
        PromptEvalCase(
            id: "zh-scope",
            input: "修一下 parser 在空輸入時 index out of range 的問題，第 412 行。"
                + "改動越少越好，不要順便重構其他地方。",
            requiredTerms: ["412"],
            goalKeywords: ["parser"],
            expectedSymbols: ["MIN_DIFF", "NO_REFACTOR"],
            forbiddenTerms: [],
            isNegated: true
        ),
        PromptEvalCase(
            id: "zh-output-chinese",
            input: "幫我在 UploaderTests.swift 加一個重試路徑的單元測試，測試不能用 sleep。",
            language: .traditionalChinese,
            requiredTerms: ["UploaderTests.swift"],
            goalKeywords: ["測試"],
            expectedSymbols: ["DETERMINISTIC_TESTS"],
            forbiddenTerms: [],
            isNegated: true
        ),
    ]

    // MARK: - Code-switched
    //
    // The normal case for this app's users, and the one where a naive
    // translation pass destroys the identifiers.

    public static let mixed: [PromptEvalCase] = [
        PromptEvalCase(
            id: "mix-refactor",
            input: "幫我 refactor 這個 uploadChunk function，不要動到 public API，"
                + "然後測試要過。",
            requiredTerms: ["uploadChunk", "API"],
            goalKeywords: ["refactor"],
            expectedSymbols: ["KEEP_API", "TEST_PASS"],
            forbiddenTerms: [],
            isNegated: true
        ),
        PromptEvalCase(
            id: "mix-debug",
            input: "那個 race condition 在 AudioRouter.swift 的 gainLock 那邊，"
                + "你看一下要怎麼修，不要加新的 dependency。",
            requiredTerms: ["AudioRouter.swift", "gainLock"],
            goalKeywords: ["race"],
            expectedSymbols: ["NO_DEPS"],
            forbiddenTerms: [],
            isNegated: true
        ),
        PromptEvalCase(
            id: "mix-schema",
            input: "在 orders table 加一個 nullable 的 created_at column，"
                + "migration 要能 rollback，而且不要 break 現有的 REST response schema。",
            requiredTerms: ["created_at", "orders"],
            goalKeywords: ["migration"],
            expectedSymbols: ["KEEP_API"],
            forbiddenTerms: [],
            isNegated: true
        ),
    ]

    // MARK: - Adversarial
    //
    // The cases most likely to break something quietly.

    public static let adversarial: [PromptEvalCase] = [
        // The compressor must not turn this into NO_DEPS. Nearly the same
        // words as `en-retry`, opposite polarity.
        PromptEvalCase(
            id: "adv-inverted-constraint",
            input: "Add the new third-party dependency swift-log and wire it into Logger.swift",
            requiredTerms: ["swift-log", "Logger.swift"],
            goalKeywords: ["dependency"],
            expectedSymbols: [],
            forbiddenTerms: ["NO_DEPS"]
        ),
        PromptEvalCase(
            id: "adv-numbers",
            input: "Set the timeout to 30 seconds, retry 3 times, and cap the queue at 128 items",
            requiredTerms: ["30", "3", "128"],
            goalKeywords: ["timeout"],
            forbiddenTerms: []
        ),
        PromptEvalCase(
            id: "adv-identifiers",
            input: "Rename maxRetryCount to maxAttempts in RetryPolicy.swift and update "
                + "--max-retries in the CLI",
            requiredTerms: ["maxRetryCount", "maxAttempts", "RetryPolicy.swift", "--max-retries"],
            goalKeywords: ["rename"],
            forbiddenTerms: []
        ),
        PromptEvalCase(
            id: "adv-short",
            // Nothing to compress; must not be pruned into nonsense.
            input: "Ship it",
            goalKeywords: ["ship"],
            forbiddenTerms: []
        ),
        PromptEvalCase(
            id: "adv-question",
            input: "Why does the uploader retry twice instead of three times?",
            requiredTerms: [],
            goalKeywords: ["why", "uploader"],
            // The prompt must still be asking, and must still be telling the
            // reader not to act. Compiling a question into an instruction is not
            // a weaker answer — it is the opposite of the one requested, and the
            // result reads perfectly well, so only an assertion catches it.
            forbiddenTerms: [],
            requiredTags: ["<question>", "<answer_first>"]
        ),
        PromptEvalCase(
            id: "adv-question-zh",
            input: "如果我用這個方式，檔案要匯出放在哪裡 rulebook 跟壓縮才有用，claude 才看得到？",
            requiredTerms: ["rulebook"],
            goalKeywords: [],
            forbiddenTerms: [],
            requiredTags: ["<question>", "<answer_first>"]
        ),
        // Four separate pieces of work in one breath. The failure this detects is
        // the middle two being flattened into background, or the last one being
        // dropped entirely.
        PromptEvalCase(
            id: "adv-multi-task",
            input: "Rewrite the renderer to emit XML tags, then let the user pick claude or codex "
                + "mode, then drop the JSON output, and finally update the README.",
            requiredTerms: ["XML", "JSON", "README"],
            goalKeywords: ["render"],
            forbiddenTerms: []
        ),

        // The corpus had no long, dense request, which is why it never caught
        // the output cap truncating one. Both of these pack several separate
        // requirements into few characters and put the one most likely to be
        // dropped — the test requirement — at the very end.
        PromptEvalCase(
            id: "adv-long-zh",
            input: "參考官方建議的寫法改成 XML 標籤輸出，並上網搜尋 claude-opus-5 的文件確認，"
                + "可以讓使用者選擇 claude 或 codex 模式，只要出提示詞的選項不用其他 JSON，"
                + "最後詳細檢查，進行程式碼測試都沒問題才行",
            requiredTerms: ["XML", "claude-opus-5", "JSON"],
            goalKeywords: ["xml"],
            // The trailing requirement. Its absence is the failure this case
            // exists to detect.
            expectedSymbols: ["TEST_PASS"],
            forbiddenTerms: [],
            isNegated: true
        ),
        PromptEvalCase(
            id: "adv-long-en",
            input: "Rewrite the renderer to emit XML tags per the official guidance, look up the "
                + "claude-opus-5 docs to confirm, let the user pick claude or codex mode, drop the "
                + "JSON output entirely, don't add dependencies, and finally make sure the whole "
                + "test suite passes",
            requiredTerms: ["XML", "claude-opus-5", "JSON"],
            goalKeywords: ["xml", "render"],
            expectedSymbols: ["TEST_PASS", "NO_DEPS"],
            forbiddenTerms: [],
            isNegated: true
        ),
    ]
}
