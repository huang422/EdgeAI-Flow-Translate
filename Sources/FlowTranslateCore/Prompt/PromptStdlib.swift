import Foundation

/// The rules shipped with the app — a standard library for prompts.
///
/// There is no rule registry to import. `awesome-cursorrules` is prose per
/// framework, not identified rules; Telegraph English and its relatives
/// substitute generic logical symbols into arbitrary text. Nothing published
/// maps a stable identifier to a constraint, which is why this exists.
///
/// **Every rule cites a source.** A rule nobody can trace is a rule nobody
/// should be asked to follow, and it is the difference between a standard
/// library and a list of opinions. `validationErrors()` enforces it.
public enum PromptStdlib {

    /// Bumped whenever the bundled rules change in a way a saved rulebook should
    /// pick up. `RulebookStore` compares it against the saved book's own version
    /// and reconciles once — see `PromptRulebook.upgrading(_:to:)`.
    ///
    /// 1: phrasing coverage and disambiguation (WEB_SEARCH variants, the thirteen
    ///    unmatchable phrasings, CITE_THE_RULE vs CITE_SOURCES,
    ///    ASK_BEFORE_DESTRUCTIVE vs EXPLAIN_FIRST).
    /// 2: Traditional Chinese rationales for the eleven counter-intuitive rules,
    ///    which a Chinese prompt was otherwise printing in English.
    /// 3: reasons moved out of the prompt and into the rules file — the file has
    ///    to be re-synced to carry them, so the version bump prompts it.
    public static let version = 3

    /// All eight categories merged. This is what a new install starts with.
    ///
    /// Stored, not computed. As a `var` it rebuilt every rule — and a fresh
    /// `UUID()` for each — on every access, and the settings pane reads it once
    /// per category row plus once more to filter, so a single toggle rebuilt the
    /// library nine times and changed every rule's identity underneath the list.
    public static let all = PromptRulebook(
        rules: coding + testing + architecture + security + git + performance
            + workflow + review
    )

    public static func category(_ category: RuleCategory) -> [PromptRule] {
        all.rules(in: category)
    }

    // MARK: - coding

    static let coding: [PromptRule] = [
        PromptRule(
            symbol: "NO_DEPS", category: .coding,
            aliases: ["NO_NEW_DEPENDENCIES"],
            match: ["no new dependencies", "no new libraries", "don't add packages",
                    "不要加套件", "不要新增套件", "不要裝新的套件", "不要引入新的相依"],
            description: "Do not add new third-party dependencies.",
            examples: ["Solve it with the standard library rather than pulling in a package.",
                       "If a dependency seems unavoidable, say so instead of adding it."],
            backends: [
                .claude: "Do not add new third-party dependencies. If one seems unavoidable, stop and say why.",
                .codex: "No new third-party dependencies.",
                .generic: "Do not add new third-party dependencies.",
            ],
            zhHant: "不要新增任何第三方相依套件。",
            source: "Project convention (CLAUDE.md); dependency-minimisation is standard supply-chain guidance (OWASP A06:2021)",
            positiveForm: "Solve it with what the project already depends on; do not add a new "
                + "third-party package. If one seems unavoidable, stop and say why."
        ),
        PromptRule(
            symbol: "MIN_DIFF", category: .coding,
            aliases: ["SMALLEST_CHANGE"],
            match: ["minimal diff", "smallest possible change", "don't reformat untouched code",
                    "最小改動", "不要順便重排", "改動越少越好"],
            description: "Make the smallest change that solves the problem; leave untouched code unformatted.",
            examples: ["Do not reformat a file you only needed to edit two lines of.",
                       "Do not reorder imports that were already there."],
            backends: [
                .claude: "Make the smallest change that solves the problem. Leave untouched code exactly as it is.",
                .codex: "Smallest possible diff. No incidental reformatting.",
            ],
            zhHant: "以最小改動解決問題；不要順手重排未涉及的程式碼。",
            source: "Anthropic Claude 4.6+/Opus 5 prompting guidance — recent models expand scope unless bounded"
        ),
        PromptRule(
            symbol: "NO_REFACTOR", category: .coding,
            match: ["no unrelated refactoring", "don't refactor unrelated code", "stay in scope",
                    "不要重構", "不要順便改其他地方", "不要動到無關的部分"],
            description: "Do not refactor anything outside the scope of this task.",
            examples: ["Fixing a bug does not license renaming the surrounding functions."],
            backends: [
                .claude: "Do not refactor code outside the scope of this task, even if it looks improvable.",
                .codex: "No refactoring outside the task scope.",
            ],
            zhHant: "不要重構本次任務範圍以外的程式碼。",
            source: "Anthropic Claude 4.6+/Opus 5 prompting guidance — scope expansion is a documented behaviour",
            positiveForm: "Keep every change inside the scope of this task; do not improve code "
                + "outside it, even where it looks improvable."
        ),
        PromptRule(
            symbol: "SOLVE_DONT_DEFER", category: .coding,
            match: ["handle the error", "don't leave it to the caller", "no todo comments",
                    "不要留 TODO", "不要丟給呼叫端處理"],
            description: "Handle error conditions in the code rather than deferring them upward or to a TODO.",
            examples: ["Create the file with a default instead of throwing FileNotFound at the caller."],
            backends: [
                .claude: "Handle error conditions where they occur. Do not leave TODOs or defer to the caller.",
                .codex: "Handle errors in place. No TODOs.",
            ],
            zhHant: "在程式碼中處理錯誤狀況，不要往上丟或留 TODO。",
            source: "Anthropic Agent Skills authoring best practices — \"Solve, don't defer\""
        ),
        PromptRule(
            symbol: "NO_MAGIC_NUMBERS", category: .coding,
            aliases: ["NO_VOODOO_CONSTANTS"],
            match: ["no magic numbers", "justify constants", "不要魔術數字", "常數要有理由"],
            description: "Every constant must be named and justified by a comment.",
            examples: ["TIMEOUT = 47 is not acceptable without saying why 47."],
            backends: [
                .claude: "Name and justify every constant. A value nobody can explain is a bug waiting to happen.",
                .codex: "Named, documented constants only.",
            ],
            zhHant: "每個常數都要具名並說明理由。",
            source: "Ousterhout, A Philosophy of Software Design — \"voodoo constants\"",
            positiveForm: "Give every constant a name and a comment saying why that value."
        ),
    ]

    // MARK: - testing

    static let testing: [PromptRule] = [
        PromptRule(
            symbol: "TEST_PASS", category: .testing,
            match: ["tests must pass", "keep tests green", "don't break the tests",
                    "run the tests and report the result", "測試要過", "不要弄壞測試",
                    "既有測試要通過", "跑測試回報結果"],
            description: "All existing tests must still pass.",
            examples: ["Run the suite before reporting the task complete."],
            backends: [
                .claude: "All existing tests must still pass. Run them and report the result honestly.",
                .codex: "Existing tests must pass.",
            ],
            zhHant: "所有既有測試必須仍然通過。",
            source: "Project CI contract (.github/workflows/ci.yml)"
        ),
        PromptRule(
            symbol: "TEST_NEW_CODE", category: .testing,
            aliases: ["COVER_NEW_BEHAVIOUR"],
            match: ["add a test", "cover the new behaviour", "要寫測試", "新功能要有測試"],
            description: "New behaviour ships with a test that would fail without it.",
            examples: ["A regression fix needs a test that reproduces the original bug."],
            backends: [
                .claude: "Add a test for new behaviour — one that fails without your change.",
                .codex: "New behaviour requires a test.",
            ],
            zhHant: "新行為要附一個沒有它就會失敗的測試。",
            source: "Beck, Test-Driven Development by Example"
        ),
        PromptRule(
            symbol: "DETERMINISTIC_TESTS", category: .testing,
            aliases: ["NO_FLAKY_TESTS"],
            match: ["no flaky tests", "deterministic tests", "no sleeps in tests",
                    "測試不要有隨機性", "不要用 sleep"],
            description: "Tests must not depend on wall-clock timing, network, or ordering.",
            examples: ["Inject a clock instead of sleeping.", "Do not depend on test execution order."],
            backends: [
                .claude: "Tests must be deterministic: no real sleeps, no network, no order dependence.",
                .codex: "Deterministic tests only — no sleeps, network, or ordering assumptions.",
            ],
            zhHant: "測試不得依賴時鐘、網路或執行順序。",
            source: "Google Testing Blog, \"Avoiding Flakey Tests\"; xUnit Test Patterns (Meszaros)"
        ),
        PromptRule(
            symbol: "NO_SKIP_TESTS", category: .testing,
            match: ["don't skip tests", "no xfail or skip", "不要跳過測試", "不要註解掉測試"],
            description: "Do not disable, skip or delete a failing test to make a build green.",
            examples: ["Fix the cause, or report that you could not."],
            backends: [
                .claude: "Never disable or delete a failing test to make the build pass. Fix it or say you could not.",
                .codex: "Do not skip or delete failing tests.",
            ],
            zhHant: "不要為了讓建置通過而停用、跳過或刪除失敗的測試。",
            source: "Project CI contract; standard continuous-integration practice (Fowler, Continuous Integration)",
            positiveForm: "Fix the failing test, or say you could not — do not disable, skip or "
                + "delete it to make the build pass."
        ),
        // The failure mode specific to a test an agent wrote, and the one none
        // of the other rules catch: a test derived from reading the
        // implementation asserts what the code *does*, so it passes by
        // construction and cannot detect that the code is wrong. The empirical
        // work on LLM test generation names this directly — tautological
        // assertions survive review and produce a false sense of security.
        PromptRule(
            symbol: "NO_TAUTOLOGICAL_TESTS", category: .testing,
            aliases: ["ASSERT_THE_SPEC", "NO_MIRROR_TESTS"],
            match: ["don't just assert what the code does", "test the behaviour not the implementation",
                    "no tautological tests", "assert against the spec",
                    "不要只斷言程式現在的行為", "測行為不要測實作", "不要寫套套邏輯的測試",
                    "斷言要對照規格"],
            description: "Assert the intended behaviour, not the current implementation.",
            examples: ["Write the expected value from the requirement, not by running the code and pasting the output.",
                       "If the test would still pass after the function is deleted and stubbed, it asserts nothing.",
                       "Do not assert on private helpers or call order unless the order IS the contract."],
            backends: [
                .claude: "Derive each assertion from the requirement, not from what the code currently returns. "
                    + "A test written by reading the implementation passes by construction and cannot detect a wrong implementation. "
                    + "State the expected value first, then check it.",
                .codex: "Assert intended behaviour, not current implementation. No tautological assertions.",
                .generic: "Assertions must come from the specification, not from observed output.",
            ],
            zhHant: "斷言要來自需求，不是來自程式目前的輸出。照著實作寫出來的測試必然通過，也就驗不出實作是錯的。",
            source: "Siddiq, Ernst & Pezzè, \"Do LLMs Generate Useful Test Oracles?\" (ASE 2025); "
                + "Software Engineering at Google ch.12 — test behaviours, not methods",
            counterIntuitive: true,
            rationale: "a test that mirrors the code always passes, so it reports success most convincingly exactly when the code is wrong",
            rationaleZhHant: "照著實作寫出來的測試必然通過，所以它最有說服力地報成功的時候，正好是實作錯的時候",
            positiveForm: "Derive each assertion from the requirement, not from what the code "
                + "currently returns, then check the code against it."
        ),
        PromptRule(
            symbol: "TEST_ONE_BEHAVIOUR", category: .testing,
            aliases: ["ONE_ASSERTION_THEME", "ARRANGE_ACT_ASSERT"],
            match: ["one behaviour per test", "arrange act assert", "keep tests focused",
                    "一個測試只驗一件事", "測試要聚焦", "不要一個測試塞很多斷言"],
            description: "One behaviour per test, structured arrange / act / assert.",
            examples: ["A failing test name should say what broke without opening the file.",
                       "Split a test that needs \"and\" in its name."],
            backends: [
                .claude: "Test one behaviour per test, laid out as arrange / act / assert, and name it after the behaviour. "
                    + "Someone unfamiliar with the code should be able to read the test and see what is required.",
                .codex: "One behaviour per test. Arrange / act / assert. Name the behaviour.",
            ],
            zhHant: "一個測試只驗一個行為，依 arrange／act／assert 結構撰寫，並以該行為命名。",
            source: "Software Engineering at Google ch.12; Google Testing Blog — Test Sizes"
        ),
        PromptRule(
            symbol: "HERMETIC_TESTS", category: .testing,
            aliases: ["SMALL_TESTS_FIRST"],
            match: ["tests must be hermetic", "no shared state between tests", "prefer unit tests",
                    "測試要自足", "測試之間不要共用狀態", "優先寫單元測試"],
            description: "Prefer small, self-contained tests that need no external resource.",
            examples: ["No shared database, no shared temp directory, no leaked global state.",
                       "Reach for an integration test only when the interaction IS what is being verified."],
            backends: [
                .claude: "Prefer small hermetic tests: one unit, no network, no shared database or temp directory, "
                    + "no state left behind for the next test. Use a larger test only when the interaction itself is the thing under test.",
                .codex: "Hermetic tests: no external resources, no shared state.",
            ],
            zhHant: "優先寫自足的小型測試：單一單元、不連網、不共用資料庫或暫存目錄、不留狀態給下一個測試。",
            source: "Google Testing Blog — Test Sizes (small / medium / large); Software Engineering at Google ch.11"
        ),
        PromptRule(
            symbol: "COVER_EDGE_CASES", category: .testing,
            match: ["test the edge cases", "boundary conditions", "測邊界條件"],
            description: "Cover empty, boundary and error inputs, not only the happy path.",
            examples: ["Empty string, zero, maximum length, and the failure branch."],
            backends: [
                .claude: "Cover empty, boundary and error inputs — not just the happy path.",
                .codex: "Include boundary and error cases.",
            ],
            zhHant: "要涵蓋空值、邊界與錯誤輸入，不只測正常路徑。",
            source: "Myers, The Art of Software Testing — boundary value analysis"
        ),
    ]

    // MARK: - architecture

    static let architecture: [PromptRule] = [
        PromptRule(
            symbol: "KEEP_API", category: .architecture,
            aliases: ["API_STABLE", "NO_BREAKING_CHANGE"],
            match: ["don't break the api", "keep the public interface", "no breaking changes",
                    "不要動 API", "保持介面不變", "不要破壞相容性"],
            description: "Do not change any public API signature or behaviour.",
            examples: ["Do not rename exported functions.", "Do not change REST response schemas."],
            backends: [
                .claude: "Keep backward compatibility. Never change public interfaces or their behaviour.",
                .codex: "Maintain existing public APIs.",
            ],
            zhHant: "不要更動任何公開 API 的簽章或行為。",
            source: "Semantic Versioning 2.0.0 §8",
            positiveForm: "Preserve every existing public API signature and behaviour; do not make "
                + "a breaking change."
        ),
        PromptRule(
            symbol: "NO_PREMATURE_ABSTRACTION", category: .architecture,
            match: ["don't over-engineer the design", "no premature abstraction", "不要過度設計",
                    "不要提前抽象"],
            description: "Do not add abstractions for requirements that do not exist yet.",
            examples: ["A single caller does not need an interface."],
            backends: [
                .claude: "Do not design for hypothetical future requirements. Do the simplest thing that works.",
                .codex: "No speculative abstractions.",
            ],
            zhHant: "不要為尚不存在的需求建立抽象層。",
            source: "Ousterhout, A Philosophy of Software Design; YAGNI (Jeffries, XP)",
            positiveForm: "Write the concrete version first and abstract on the third use; do not "
                + "design for requirements that do not exist yet."
        ),
        PromptRule(
            symbol: "BOUNDARY_VALIDATION_ONLY", category: .architecture,
            match: ["validate at the boundary", "trust internal code", "只在邊界驗證"],
            description: "Validate at system boundaries; trust internal invariants.",
            examples: ["Validate user input and external API responses, not every internal call."],
            backends: [
                .claude: "Validate at system boundaries (user input, external APIs). Trust internal guarantees — do not add defensive checks for states that cannot happen.",
                .codex: "Validate at boundaries only.",
            ],
            zhHant: "只在系統邊界驗證；內部程式碼信任既有保證。",
            source: "Ousterhout, A Philosophy of Software Design — defining errors out of existence"
        ),
        PromptRule(
            symbol: "SINGLE_OWNER", category: .architecture,
            match: ["one owner per rule", "no duplicated logic", "邏輯不要重複", "單一來源"],
            description: "Each behaviour has exactly one place that decides it.",
            examples: ["Do not repeat a validation rule in both the client and the handler."],
            backends: [
                .claude: "Keep one owner per behaviour. Duplicated rules drift apart and then contradict each other.",
                .codex: "One source of truth per behaviour.",
            ],
            zhHant: "每個行為只能有一處決定，不要重複。",
            source: "Sentry prompt-optimizer skill (Apache-2.0) — \"keep one owner per behavior rule\""
        ),
        PromptRule(
            symbol: "NO_COMPAT_SHIMS", category: .architecture,
            aliases: ["NO_FEATURE_FLAGS"],
            match: ["no feature flags", "no backwards compatibility shim", "不要加相容層",
                    "不要加 feature flag"],
            description: "Change the code directly rather than adding a flag or shim to preserve the old path.",
            examples: ["If nothing else calls the old path, delete it."],
            backends: [
                .claude: "Do not add feature flags or compatibility shims when you can simply change the code.",
                .codex: "Change code directly; no shims or flags.",
            ],
            zhHant: "能直接改程式碼時，不要加旗標或相容層。",
            source: "Project convention (CLAUDE.md); trunk-based development guidance (Hammant)",
            positiveForm: "Update the callers so there is one way to do it."
        ),
    ]

    // MARK: - security

    static let security: [PromptRule] = [
        PromptRule(
            symbol: "NO_SECRETS_IN_CODE", category: .security,
            match: ["no hardcoded secrets", "no api keys in code", "不要把金鑰寫進程式",
                    "不要硬編密碼"],
            description: "Never hardcode credentials, tokens or keys; read them from the environment.",
            examples: ["Read ANTHROPIC_API_KEY from the environment, never a literal."],
            backends: [
                .claude: "Never hardcode credentials, tokens or keys. Read them from the environment or a secret store.",
                .codex: "No hardcoded secrets — use environment variables.",
            ],
            zhHant: "絕不把憑證、權杖或金鑰寫死在程式碼中，一律從環境讀取。",
            source: "OWASP Top 10 A07:2021 — Identification and Authentication Failures",
            positiveForm: "Read every credential from the environment; never hardcode a token, "
                + "key or password."
        ),
        PromptRule(
            symbol: "VALIDATE_INPUT", category: .security,
            match: ["validate user input", "sanitize input", "驗證輸入", "過濾使用者輸入"],
            description: "Treat all external input as untrusted and validate it before use.",
            examples: ["Resolve and bounds-check a path before opening it."],
            backends: [
                .claude: "Treat every external input as untrusted. Validate and bound it before use, especially paths and queries.",
                .codex: "Validate all external input.",
            ],
            zhHant: "所有外部輸入都視為不可信，使用前必須驗證。",
            source: "OWASP ASVS v4.0 §5 — Validation, Sanitization and Encoding"
        ),
        PromptRule(
            symbol: "LEAST_PRIVILEGE", category: .security,
            match: ["least privilege", "minimum permissions", "最小權限"],
            description: "Grant the minimum permission that makes the task possible.",
            examples: ["A read-only token where nothing is written."],
            backends: [
                .claude: "Grant the minimum permission the task needs, and no more.",
                .codex: "Least privilege for all credentials and scopes.",
            ],
            zhHant: "只授予完成任務所需的最小權限。",
            source: "Saltzer & Schroeder (1975), The Protection of Information in Computer Systems"
        ),
        PromptRule(
            symbol: "NO_EVAL", category: .security,
            match: ["no eval of untrusted input", "no dynamic code execution", "不要用 eval", "不要動態執行程式碼"],
            description: "Do not evaluate or execute strings built from input.",
            examples: ["Parse the expression rather than eval-ing it."],
            backends: [
                .claude: "Do not evaluate or shell out to strings built from input. Parse it instead.",
                .codex: "No eval or dynamic execution of input.",
            ],
            zhHant: "不要對由輸入組成的字串做求值或執行。",
            source: "OWASP Top 10 A03:2021 — Injection",
            positiveForm: "Parse untrusted input with a real parser; never evaluate or execute a "
                + "string built from it."
        ),
        PromptRule(
            symbol: "ASK_BEFORE_DESTRUCTIVE", category: .security,
            match: ["ask before deleting", "confirm destructive actions",
                    "刪除前先問", "破壞性操作先確認", "刪檔前先確認"],
            description: "Ask before deleting files, dropping data, or running irreversible commands.",
            examples: ["Confirm before `rm -rf`, a force push, or a schema drop."],
            backends: [
                .claude: "Ask before any irreversible action — deleting files, dropping data, force-pushing. For reversible changes, proceed.",
                .codex: "Confirm before irreversible operations.",
            ],
            zhHant: "刪除檔案、清除資料或執行不可逆指令前先詢問。",
            source: "Anthropic agent-design guidance — gate hard-to-reverse actions"
        ),
    ]

    // MARK: - git

    static let git: [PromptRule] = [
        PromptRule(
            symbol: "CONVENTIONAL_COMMITS", category: .git,
            match: ["conventional commits", "commit message format", "commit 格式", "提交訊息格式"],
            description: "Commit messages follow Conventional Commits: type(scope): summary.",
            examples: ["feat(auth): add JWT validation", "fix(reports): correct timezone handling"],
            backends: [
                .claude: "Write commit messages as Conventional Commits — type(scope): summary.",
                .codex: "Use Conventional Commits format.",
            ],
            zhHant: "commit 訊息使用 Conventional Commits 格式：type(scope): 摘要。",
            source: "Conventional Commits 1.0.0"
        ),
        PromptRule(
            symbol: "SMALL_COMMITS", category: .git,
            match: ["one change per commit", "atomic commits", "一次一個變更"],
            description: "One logical change per commit.",
            examples: ["Do not mix a refactor and a bug fix in one commit."],
            backends: [
                .claude: "Keep each commit to one logical change.",
                .codex: "Atomic commits — one change each.",
            ],
            zhHant: "每個 commit 只包含一項邏輯變更。",
            source: "Git SCM Book §5.2 — Commit Guidelines"
        ),
        PromptRule(
            symbol: "BRANCH_FIRST", category: .git,
            match: ["don't commit to main", "branch first", "不要直接改 main", "先開分支"],
            description: "Never commit directly to the default branch; branch first.",
            examples: ["Create a feature branch before the first commit."],
            backends: [
                .claude: "Never commit to the default branch. Create a branch first.",
                .codex: "Branch before committing; never commit to main.",
            ],
            zhHant: "不要直接 commit 到預設分支，先開一個分支。",
            source: "Trunk-based development / GitHub Flow"
        ),
        PromptRule(
            symbol: "NO_FORCE_PUSH", category: .git,
            match: ["no force push", "don't rewrite history", "不要 force push", "不要改寫歷史"],
            description: "Do not force-push or rewrite history on a shared branch.",
            examples: ["Add a revert commit rather than rewriting the pushed history."],
            backends: [
                .claude: "Never force-push or rewrite history on a shared branch.",
                .codex: "No force-push on shared branches.",
            ],
            zhHant: "不要對共享分支做 force push 或改寫歷史。",
            source: "Git SCM Book §3.6 — The Perils of Rebasing"
        ),
        PromptRule(
            symbol: "NO_AI_ATTRIBUTION", category: .git,
            match: ["no ai attribution", "don't mention claude in commits",
                    "commit 不要提 AI", "不要加 AI 署名"],
            description: "Do not add AI tool attribution to commits, PR bodies or credits.",
            examples: ["No Co-Authored-By or 'Generated with' trailers."],
            backends: [
                .claude: "Do not add AI attribution to commit messages, PR descriptions or credits.",
                .codex: "No AI attribution in commits or PRs.",
            ],
            zhHant: "commit、PR 內文與致謝都不要加上 AI 工具署名。",
            source: "Project convention (see repository memory: no-ai-attribution-anywhere)"
        ),
    ]

    // MARK: - performance

    static let performance: [PromptRule] = [
        PromptRule(
            symbol: "MEASURE_FIRST", category: .performance,
            // Widened after a live eval run missed this rule entirely: the
            // model paraphrases, so a short phrase list under-matches. The
            // request said "先量測再最佳化" and the compiled English came back
            // as wording none of the three original phrases covered.
            match: ["measure before optimizing", "measure before you change anything",
                    "profile first", "profile before optimizing", "benchmark first",
                    "measure first", "don't optimize blind",
                    "先量測再最佳化", "先量測", "先測量", "先做效能量測", "量測後再最佳化",
                    "不要盲目最佳化"],
            description: "Measure before optimizing; report the numbers.",
            examples: ["Profile the slow path before rewriting it."],
            backends: [
                .claude: "Measure before optimizing, and report the before/after numbers rather than asserting an improvement.",
                .codex: "Profile before optimizing; report measurements.",
            ],
            zhHant: "最佳化前先量測，並回報前後數字。",
            source: "Knuth (1974), Structured Programming with go to Statements"
        ),
        PromptRule(
            symbol: "NO_N_PLUS_ONE", category: .performance,
            match: ["no n+1 queries", "batch the queries", "不要 n+1 查詢"],
            description: "Do not issue one query or request per item in a loop.",
            examples: ["Fetch the whole set once instead of once per row."],
            backends: [
                .claude: "Do not query or request once per item in a loop. Batch it.",
                .codex: "Avoid N+1 queries — batch instead.",
            ],
            zhHant: "不要在迴圈中對每個項目各發一次查詢或請求。",
            source: "Fowler, Patterns of Enterprise Application Architecture — Lazy Load pitfalls",
            positiveForm: "Fetch the related rows in one query; do not issue a query or request "
                + "per item in a loop."
        ),
        PromptRule(
            symbol: "BOUND_ALLOCATIONS", category: .performance,
            aliases: ["BOUND_MEMORY"],
            match: ["bound the buffer", "cap the queue", "限制記憶體用量", "佇列要有上限"],
            description: "Every queue, cache and buffer has an explicit maximum.",
            examples: ["Cap the pending queue and drop oldest rather than growing without limit."],
            backends: [
                .claude: "Give every queue, cache and buffer an explicit bound, and say what happens when it is reached.",
                .codex: "Bound all queues, caches and buffers.",
            ],
            zhHant: "每個佇列、快取與緩衝區都要有明確上限。",
            source: "Project convention (bounded MLX queue, transcript cap); Release It! (Nygard) — Bulkheads"
        ),
        PromptRule(
            symbol: "STREAM_LARGE_IO", category: .performance,
            match: ["stream large files", "don't load it all into memory", "大檔要串流"],
            description: "Stream large inputs rather than reading them fully into memory.",
            examples: ["Process the file line by line instead of reading it whole."],
            backends: [
                .claude: "Stream large inputs; do not read an unbounded file fully into memory.",
                .codex: "Stream large I/O.",
            ],
            zhHant: "大型輸入要串流處理，不要整份讀進記憶體。",
            source: "Release It! (Nygard) — Unbounded Result Sets"
        ),
        PromptRule(
            symbol: "CACHE_INVALIDATION_PLAN", category: .performance,
            match: ["say how the cache is invalidated", "cache invalidation", "快取要說明失效條件"],
            description: "Any cache added must state how and when it is invalidated.",
            examples: ["A TTL, an explicit eviction trigger, or a versioned key."],
            backends: [
                .claude: "If you add a cache, state its invalidation rule. A cache with no invalidation plan is a bug with a delay.",
                .codex: "Document cache invalidation for any cache you add.",
            ],
            zhHant: "新增快取時必須說明失效方式與時機。",
            source: "Fowler, Patterns of Enterprise Application Architecture — caching strategies"
        ),
    ]

    // MARK: - workflow
    //
    // How the agent should work, rather than what it should build. These are the
    // rules most likely to be ignored, and the ones where wording matters most.
    //
    // Compact Constraint Encoding (arXiv 2604.07192) measured that conventional
    // constraints are obeyed 99%+ of the time from a bare symbol, while
    // counter-intuitive ones land anywhere from 10% to 100% — and that no
    // encoding format changes this. Most rules in this category ask the agent to
    // *not* do the helpful-seeming thing, so they are marked `counterIntuitive`
    // and carry their reason into the prompt. That is the only lever the
    // evidence supports.

    static let workflow: [PromptRule] = [
        PromptRule(
            symbol: "EXPLAIN_FIRST", category: .workflow,
            aliases: ["PLAN_FIRST", "NO_CODE_UNTIL_APPROVED"],
            match: ["explain before implementing", "plan before you code", "don't edit until I approve",
                    "先說明再實作", "先講方案", "先說明後再實作", "等我確認再動手", "先跟我說明",
                    "動手前先說明", "動手前先跟我說"],
            description: "Explain the approach and wait for approval before changing any file.",
            examples: ["Describe the change and the reason, then stop.",
                       "List the files you would touch before touching them."],
            backends: [
                .claude: "Explain your approach and the reasoning behind it, then stop and wait for approval before editing any file.",
                .codex: "Explain the plan first. Do not edit files until approved.",
                .generic: "Explain the approach before making changes, and wait for approval.",
            ],
            zhHant: "先說明作法與理由，等我確認後才動任何檔案。",
            source: "Anthropic — Claude Code best practices (plan mode); arXiv 2509.14744 Development Process (37.2%)",
            counterIntuitive: true,
            rationale: "an unrequested edit costs more to review and undo than the explanation costs to read",
            rationaleZhHant: "沒被要求的改動，審查與復原的成本高於先讀一段說明"
        ),
        PromptRule(
            symbol: "RESEARCH_FIRST", category: .workflow,
            aliases: ["READ_BEFORE_WRITE"],
            match: ["read the existing code first", "research before proposing",
                    "先研究", "先看過既有程式碼", "先查清楚再說", "研究後再提"],
            description: "Read the existing code and documentation before proposing a change.",
            examples: ["Open the file being changed before describing how to change it.",
                       "Quote the current behaviour rather than assuming it."],
            backends: [
                .claude: "Read the relevant existing code and docs before proposing anything. Base the proposal on what is actually there, not on what is typical.",
                .codex: "Read the existing code before proposing changes.",
                .generic: "Inspect the current implementation before proposing a change.",
            ],
            zhHant: "提出方案前先讀過既有的程式碼與文件，依實際情況而非慣例。",
            source: "Anthropic — Claude Code best practices (explore, plan, code, commit)",
            counterIntuitive: true,
            rationale: "a plausible answer built on an assumed codebase is harder to catch than an obviously wrong one",
            rationaleZhHant: "建立在臆測的程式碼之上的答案看起來合理，比明顯錯誤的答案更難被發現"
        ),
        PromptRule(
            symbol: "WEB_SEARCH", category: .workflow,
            aliases: ["CHECK_CURRENT_DOCS"],
            match: ["search the web", "check the official docs", "look up the current version",
                    "search online", "look it up online", "look it up on the web",
                    "上網搜尋", "查官方文件", "查最新版本", "上網查", "上網查資料",
                    "查網路上的做法"],
            description: "Look up official documentation and current versions rather than relying on training data.",
            examples: ["Check the current API before using it.",
                       "Verify a version number against the registry, not from memory."],
            backends: [
                .claude: "Search the web for official documentation and current versions rather than relying on training data. Cite what you found.",
                .codex: "Check official docs online for anything version-dependent.",
                .generic: "Consult current official documentation rather than recalling it.",
            ],
            zhHant: "查官方文件與目前版本，不要只依賴訓練資料，並附上出處。",
            source: "Anthropic — Claude Code best practices (verify, don't trust); model knowledge cutoff",
            counterIntuitive: true,
            rationale: "training data has a cutoff and recalled API details are confidently wrong more often than absent",
            rationaleZhHant: "訓練資料有時間截點，憑記憶回想的 API 細節通常不是缺漏，而是自信地講錯"
        ),
        PromptRule(
            symbol: "FULL_REVIEW", category: .workflow,
            aliases: ["AUDIT_ALL", "CHECK_REDUNDANCY"],
            match: ["review everything", "check for redundancy and errors", "full audit",
                    "全面檢查", "全面測試檢查", "檢查有沒有冗餘", "檢查冗餘或錯誤", "整體檢查一遍"],
            description: "Review the whole area for redundancy, dead code, errors and omissions — not only the part named.",
            // The caveat is part of the rule, not a footnote: Anthropic's Opus 5
            // guide states that standing verification instructions cause
            // over-verification and burn tokens with no quality gain. This rule
            // earns its keep when given per task; installed as a permanent
            // session rule it is the exact anti-pattern that guide names.
            examples: ["Report unused code found along the way.",
                       "Report problems outside the reported symptom.",
                       "Give this per task. As a standing session rule it causes the "
                        + "over-verification Anthropic's Opus 5 guide warns about."],
            backends: [
                .claude: "Review the whole area, not just the part I pointed at. Report redundancy, dead code, errors and omissions, and report everything you find rather than pre-filtering by severity.",
                .codex: "Review the whole area for redundancy, dead code and errors — not only the named part.",
                .generic: "Audit the surrounding code for redundancy and errors, not just the reported issue.",
            ],
            zhHant: "整個範圍都要檢查冗餘、死碼、錯誤與遺漏，不只看我指出的地方；找到什麼就全部回報，不要先依嚴重度過濾。",
            source: "arXiv 2509.14744 Maintenance (19.8%); Anthropic — Prompting Claude Opus 5 (report everything, filter separately)"
        ),
        PromptRule(
            symbol: "REPORT_FAILURES", category: .workflow,
            aliases: ["HONEST_STATUS"],
            match: ["say if tests fail", "report what you skipped", "don't only report success",
                    "測試失敗要說", "略過的步驟要講", "不要只報成功", "如實回報",
                    "失敗要老實說", "有失敗要告訴我"],
            description: "State plainly when tests fail, a step was skipped, or part of the task is incomplete.",
            examples: ["Paste the failing output rather than summarizing it as 'mostly working'.",
                       "Name what was left undone and why."],
            backends: [
                .claude: "If tests fail, say so and show the output. If a step was skipped or a part is unfinished, say which and why. Report completion only when the work is actually done.",
                .codex: "Report failures and skipped steps explicitly. Do not claim success unless verified.",
                .generic: "State failures, skipped steps and incomplete work explicitly.",
            ],
            zhHant: "測試失敗要講並附上輸出；略過或未完成的部分要說明是哪些、為什麼。真正完成才回報完成。",
            source: "AGENTS.md three-tier boundaries (Always / Ask First / Never); arXiv 2509.14744 Development Process",
            counterIntuitive: true,
            rationale: "an overstated success is discovered later at much higher cost than an admitted failure",
            rationaleZhHant: "誇大的成功會在更晚、成本更高的時候才被發現，坦承的失敗不會"
        ),
        PromptRule(
            symbol: "ASK_WHEN_UNSURE", category: .workflow,
            aliases: ["CLARIFY_DONT_GUESS"],
            match: ["ask if you're not sure", "don't guess, ask", "clarify first",
                    "ask me if anything is unclear", "不確定就問", "不要用猜的", "有疑問先問",
                    "不清楚就問我"],
            description: "Ask when the request is genuinely ambiguous instead of guessing.",
            examples: ["Ask which of two readings is meant when they lead to different work.",
                       "Do not invent a requirement to fill a gap."],
            backends: [
                .claude: "When different readings of the request would lead to materially different work, ask. Make routine judgement calls yourself; do not invent requirements to fill gaps.",
                .codex: "Ask when the request is ambiguous rather than guessing.",
                .generic: "Ask for clarification on genuine ambiguity instead of assuming.",
            ],
            zhHant: "不同解讀會導致不同結果時就問；一般判斷自己做，但不要憑空補上需求。",
            source: "AGENTS.md three-tier boundaries — Ask First; Anthropic — Prompting Claude Opus 5 (task scope)",
            counterIntuitive: true,
            rationale: "a guess that looks complete is not visibly a guess",
            rationaleZhHant: "看起來完整的猜測，從外表看不出來是猜的"
        ),
        PromptRule(
            symbol: "NO_PARTIAL_WORK", category: .workflow,
            aliases: ["FINISH_THE_TASK"],
            match: ["finish the whole task", "don't just do the easy part", "no stubs or placeholders",
                    "no stubs or todos", "不要只做簡單的部分", "整個做完", "不要留半成品",
                    "不要只做一半"],
            description: "Finish the whole task rather than the easy part, and never leave stubs presented as done.",
            examples: ["If part of the scope is blocked, complete the rest and say what was left.",
                       "No TODO placeholders passed off as an implementation."],
            backends: [
                .claude: "Finish the whole task. If one part is genuinely blocked, complete everything else and say explicitly what you left out and why — scaling the work down is my call, not yours.",
                .codex: "Complete the full task. State explicitly anything left undone.",
                .generic: "Complete the whole task; report any part left undone.",
            ],
            zhHant: "整個任務做完。若某部分確實卡住，其餘全部完成並明說略過了什麼、為什麼——要不要縮減範圍是我決定。",
            source: "Anthropic — Prompting Claude Opus 5 (completes full tasks rather than leaving stubs)",
            counterIntuitive: true,
            rationale: "a partial result reported as complete is worse than no result, because it stops anyone looking",
            rationaleZhHant: "把半成品當成完成回報，比沒有結果更糟，因為不會再有人去看它",
            positiveForm: "Finish the whole task, and say plainly what you had to leave out; "
                + "never present a stub as done."
        ),
        // Opus 5 delegates more readily than earlier models, and the guide gives
        // the wording verbatim. Without a cap, a two-file change spawns a team.
        PromptRule(
            symbol: "LIMIT_DELEGATION", category: .workflow,
            aliases: ["NO_SUBAGENT_SPRAWL"],
            match: ["don't spawn subagents for small tasks", "limit delegation", "do the work yourself",
                    "小事不要開子代理", "不要濫用子代理", "自己做就好"],
            description: "Delegate only large, genuinely independent tracks of work.",
            examples: ["A wide multi-file investigation: delegate.",
                       "Anything finishable in a handful of tool calls: do it yourself.",
                       "Never use a subagent to check your own work."],
            backends: [
                .claude: "Delegate to a subagent only for large tasks that are genuinely independent "
                    + "and parallelizable, such as a wide multi-file investigation. Do not delegate work "
                    + "you can finish yourself in a handful of tool calls, and do not use subagents to "
                    + "verify your own work. If one subagent can do it, use one.",
                .codex: "Delegate only large independent tasks. No subagents for verification.",
            ],
            zhHant: "只有大型且真正獨立可平行的工作才委派子代理。幾個工具呼叫就能做完的自己做，"
                + "也不要用子代理來複查自己的成果。",
            source: "Anthropic — Prompting Claude Opus 5, \"Controlling subagent spawning\" "
                + "(wording adapted from the guide's own example)",
            counterIntuitive: true,
            rationale: "delegating feels thorough, but it multiplies cost and time on work that was never parallel",
            rationaleZhHant: "分派出去感覺比較周全，但那些工作本來就無法平行，只是把成本和時間翻倍",
            positiveForm: "Do the work yourself unless it is large, genuinely independent and "
                + "parallelizable — and check your own work yourself rather than with a subagent."
        ),
        // From hex/claude-council's synthesis prompt (MIT), which asks for
        // "one strong recommendation over several hedged ones". The failure it
        // names is real and not specific to that tool: an agent that answers a
        // decision with five options has moved the work back to you.
        PromptRule(
            symbol: "ONE_RECOMMENDATION", category: .workflow,
            aliases: ["DECIDE_DONT_HEDGE"],
            match: ["give one recommendation", "don't hedge the recommendation", "pick one and say why",
                    "給一個建議就好", "不要模稜兩可", "直接說你建議哪個"],
            description: "Give one recommendation with its reason, not a menu of options.",
            examples: ["\"Use X because Y\" — not \"you could use X, or Y, or Z\".",
                       "If two options are genuinely close, say which you would pick and what would change your mind."],
            backends: [
                .claude: "Give one recommendation and the reason for it. If the alternatives are close, "
                    + "name the one you would choose and what would change your mind — do not hand back "
                    + "a list for me to decide from.",
                .codex: "One recommendation with a reason. No option menus.",
            ],
            zhHant: "給一個建議與理由。若選項確實接近，說出你會選哪個、以及什麼情況會改變你的判斷——"
                + "不要把清單丟回來讓我選。",
            source: "hex/claude-council synthesis prompt (MIT) — \"prefer one strong recommendation over "
                + "several hedged ones\"; Anthropic — Prompting Claude Opus 5 (response verbosity)",
            positiveForm: "Give one recommendation and the reason for it, not a menu of options "
                + "to choose from."
        ),
        // Opus 5's user-facing answers run longer than earlier models', and the
        // effort parameter controls how much it *thinks*, not how much it says —
        // so length has to be asked for in the prompt or not at all.
        PromptRule(
            symbol: "BE_CONCISE", category: .workflow,
            aliases: ["SHORT_ANSWERS"],
            match: ["keep it brief", "keep the answer concise", "don't write an essay",
                    "回答簡潔", "不要長篇大論", "講重點就好"],
            description: "Keep the answer focused; spend the words on the answer, not the caveats.",
            examples: ["A high-level summary unless depth is asked for.",
                       "Short disclaimers, if any."],
            backends: [
                .claude: "Keep responses focused, brief, and concise. Keep disclaimers and caveats "
                    + "short, and spend most of the response on the main answer. When asked to explain "
                    + "something, give a high-level summary unless an in-depth explanation is "
                    + "specifically requested.",
                .codex: "Keep responses brief. Answer first, caveats short.",
            ],
            zhHant: "回覆聚焦簡潔，聲明與但書寫短，篇幅花在主要答案上。要求說明時先給高層次摘要，"
                + "除非明確要求深入。",
            source: "Anthropic — Prompting Claude Opus 5, \"Response length and verbosity\" "
                + "(wording taken from the guide's own example)",
            positiveForm: "Answer first and keep it brief — spend the words on the answer, not on "
                + "caveats and disclaimers."
        ),
        // Separate from conversational length: the guide calls out files written
        // to disk specifically, because those grew independently.
        PromptRule(
            symbol: "NO_PADDING", category: .workflow,
            aliases: ["RIGHT_SIZED_DOCS"],
            match: ["don't pad the document", "no filler sections", "no boilerplate sections",
                    "文件不要灌水", "不要湊字數", "不要加樣板段落"],
            description: "Size a written document to the task: cover the substance, add no filler.",
            examples: ["No redundant summary of what the reader just read.",
                       "No boilerplate section headings with nothing under them."],
            backends: [
                .claude: "Match the length of written documents to what the task needs: cover the "
                    + "substance, but do not pad with filler sections, redundant summaries, or boilerplate.",
                .codex: "Size documents to the task. No filler or boilerplate sections.",
            ],
            zhHant: "寫入檔案的文件長度要符合任務需求：內容講足，但不要用樣板段落、重複摘要或制式文字灌水。",
            source: "Anthropic — Prompting Claude Opus 5, \"Written deliverable length\" "
                + "(wording taken from the guide's own example)",
            positiveForm: "Size a written document to what the task needs: cover the substance, "
                + "and do not pad it with filler sections, redundant summaries or boilerplate."
        ),
        // The half of the scope paragraph that neither MIN_DIFF nor
        // ASK_WHEN_UNSURE covers: what to do when the request looks wrong.
        PromptRule(
            symbol: "FLAG_AND_CONTINUE", category: .workflow,
            aliases: ["SAY_SO_AND_PROCEED"],
            match: ["say so and carry on", "flag it but do it anyway", "don't silently change the task",
                    "有疑慮講一句然後照做", "不要自己改掉需求", "覺得有問題先說再做"],
            description: "If the request looks mistaken, say so in a sentence and do it as asked anyway.",
            examples: ["State the concern, then deliver the requested scope.",
                       "Do not quietly substitute what you think was meant."],
            backends: [
                .claude: "If the request seems mistaken or a better approach exists, say so in a "
                    + "sentence and continue with the task as asked — rather than quietly narrowing, "
                    + "widening, or transforming it. Scaling the work down is my call, not yours.",
                .codex: "Flag concerns in one sentence, then do the task as asked.",
            ],
            zhHant: "覺得需求有問題或有更好做法，用一句話說出來，然後仍照原樣完成——"
                + "不要無聲地縮小、放大或改寫任務。要不要縮減是我決定。",
            source: "Anthropic — Prompting Claude Opus 5, \"Task scope and over-verification\" "
                + "(wording taken from the guide's own example)",
            counterIntuitive: true,
            rationale: "an agent that spots a problem either stops or silently redefines the task; "
                + "saying it in one line and continuing is neither, and is what you actually want",
            rationaleZhHant: "發現問題的代理不是停下來，就是默默改寫任務；"
                + "用一句話說出來然後照做，兩者都不是，也才是你真正要的",
            positiveForm: "Name the concern in one sentence, then deliver exactly what was asked."
        ),
        PromptRule(
            symbol: "CITE_SOURCES", category: .workflow,
            aliases: ["SHOW_EVIDENCE"],
            match: ["cite your sources", "cite sources", "show file and line",
                    "link what you found", "附上出處", "要引用出處", "引用出處",
                    "給檔案行號", "說明依據"],
            description: "Support claims with a file:line reference or a link.",
            examples: ["`Sources/Uploader.swift:42` rather than 'in the uploader'.",
                       "Link the documentation page a version claim came from."],
            backends: [
                .claude: "Support each claim with a `file:line` reference or a link, so I can check it without re-deriving it.",
                .codex: "Cite file:line or a URL for each claim.",
                .generic: "Give a file:line reference or link for factual claims.",
            ],
            zhHant: "每項結論附上 `檔案:行號` 或連結，讓我能直接查證。",
            source: "Anthropic — Claude Code best practices (verify, don't trust)"
        ),
    ]

    // MARK: - review
    //
    // Every rule here exists to raise precision, because that is the only thing
    // wrong with LLM code review. Recall is already good — GPT-4 scored 88.2%
    // recall against 22.6% precision on smart contracts — and the consequences
    // of the imbalance are no longer hypothetical: curl permanently closed its
    // bug bounty after AI reports pushed the confirmed rate under 5%.

    static let review: [PromptRule] = [
        // The finding that three independent sources agree on, and the one that
        // reads backwards: asking for fewer findings gets you worse findings,
        // not fewer false ones.
        PromptRule(
            symbol: "REPORT_ALL_THEN_FILTER", category: .review,
            aliases: ["TWO_PASS_REVIEW"],
            match: ["report everything then filter", "two pass review",
                    "don't pre-filter by severity", "先全部列出再篩選",
                    "分兩階段審查", "不要只報高嚴重度"],
            description: "Find everything in one pass, then judge severity in a separate pass.",
            examples: ["Pass 1: list every candidate with evidence. Pass 2: discard the ones that do not hold.",
                       "Do NOT write \"only report high-severity issues\" — that reduces what is found, not what is wrong."],
            backends: [
                .claude: "Review in two passes. First list every candidate finding with its evidence, "
                    + "holding nothing back. Then re-examine each one independently and discard any you "
                    + "cannot demonstrate. Do not filter by severity while you are still looking.",
                .codex: "Two passes: find everything first, then filter. No severity filter during discovery.",
                .generic: "Separate discovery from filtering. Find broadly, then verify each finding.",
            ],
            zhHant: "分兩階段審查：第一階段列出所有候選問題與證據，不要保留；第二階段逐一重新檢驗，"
                + "無法證明的就刪掉。搜尋階段不要用嚴重度過濾。",
            source: "Anthropic — Prompting Claude Opus 5 (\"ask it to report everything and filter in a "
                + "separate pass\"); anthropics/claude-code code-review plugin (Stage 3 detection, "
                + "Stage 5 independent validation); G-Research, \"Building a code review tool\" "
                + "(single pass 25–30% false positives; two-pass substantially better)",
            counterIntuitive: true,
            rationale: "a model told to report only serious issues reports fewer issues, not fewer wrong ones",
            rationaleZhHant: "叫模型只回報重要問題，得到的是更少的問題，不是更少的錯誤問題"
        ),
        PromptRule(
            symbol: "CONCRETE_FAILURE", category: .review,
            aliases: ["SHOW_THE_BREAK"],
            match: ["show how it breaks", "give a failing input", "no hypothetical issues",
                    "要能說出怎麼壞", "給出具體會失敗的輸入", "不要講可能有問題"],
            description: "Every finding states inputs or state that produce a wrong result.",
            examples: ["\"Empty array → index out of range at line 412\", not \"this might crash\".",
                       "If you cannot name the input that breaks it, it is not a finding."],
            backends: [
                .claude: "State the concrete failure for each finding: the input or state, and the wrong "
                    + "output or crash it produces. A finding you cannot make fail is a guess — drop it.",
                .codex: "Each finding needs a concrete failing input and its wrong result.",
            ],
            zhHant: "每個問題都要寫出具體會失敗的輸入或狀態，以及錯誤的結果。舉不出來的就不是問題。",
            source: "anthropics/claude-code code-review plugin — never flag \"input-dependent potential issues\"",
            counterIntuitive: true,
            rationale: "\"this could be a problem\" is unfalsifiable, and unfalsifiable findings are what buried curl's bug bounty",
            rationaleZhHant: "「這可能有問題」無法被否證，而無法否證的發現正是壓垮 curl 漏洞獎金計畫的東西"
        ),
        PromptRule(
            symbol: "NO_STYLE_NITS", category: .review,
            aliases: ["SKIP_LINTABLE"],
            match: ["skip style comments", "no style nitpicks", "the linter handles that",
                    "不要挑格式", "不要雞蛋裡挑骨頭", "lint 抓得到的不用講"],
            description: "Do not raise style, formatting or anything a linter already catches.",
            examples: ["No naming preferences, no import order, no line length.",
                       "No \"consider extracting this\" without a defect behind it."],
            backends: [
                .claude: "Do not raise style, formatting, naming preferences, or anything a linter "
                    + "already catches. Every comment should cost the reader less than it saves them.",
                .codex: "No style or lint-catchable comments.",
            ],
            zhHant: "不要提格式、命名偏好或 linter 抓得到的東西。每則意見對讀者的價值要大於閱讀成本。",
            source: "anthropics/claude-code code-review plugin — \"Never flag: style or quality concerns, "
                + "subjective improvements, linter-catchable problems\"",
            positiveForm: "Comment where there is a defect and nowhere else — not on style, "
                + "formatting, or anything a linter already catches."
        ),
        PromptRule(
            symbol: "NO_PREEXISTING", category: .review,
            match: ["only review the change", "don't flag pre-existing issues",
                    "只看這次的改動", "不要挑原本就有的問題"],
            description: "Review the change, not the code it happens to sit next to.",
            examples: ["A bug that predates this diff belongs in an issue, not this review."],
            backends: [
                .claude: "Review what this change does. Problems that predate it are out of scope — "
                    + "note them separately at most, never as findings against this change.",
                .codex: "Only review the diff. Pre-existing issues are out of scope.",
            ],
            zhHant: "只審查這次的改動。原本就存在的問題不算這次的發現。",
            source: "anthropics/claude-code code-review plugin — \"Never flag: pre-existing issues\"",
            positiveForm: "Review what this change does; do not raise problems that predate it as "
                + "findings against it."
        ),
        PromptRule(
            symbol: "CITE_THE_RULE", category: .review,
            aliases: ["QUOTABLE_EVIDENCE"],
            match: ["quote the project rule you are citing", "quote the rule with its file and line",
                    "no invented rules", "不要自己發明規則", "規則要引用專案檔案",
                    "只能引用專案裡寫過的規則"],
            description: "A finding that cites a rule must quote it and give its location.",
            examples: ["Quote the CLAUDE.md line, with the file and line number.",
                       "A rule you cannot quote does not exist — drop the finding."],
            backends: [
                .claude: "When a finding rests on a project rule, quote the rule verbatim with its file "
                    + "and line. If you cannot find the text you are citing, you invented it — drop the finding.",
                .codex: "Cite project rules verbatim with file:line, or drop the finding.",
            ],
            zhHant: "引用專案規則時要逐字引述並附上檔案與行號。找不到原文就是你自己編的，該筆刪掉。",
            source: "G-Research, \"Building a code review tool\" — rule-index verification rejects "
                + "invented or misspelled rules; anthropics/claude-code plugin requires quotable evidence"
        ),
        PromptRule(
            symbol: "RANK_BY_SEVERITY", category: .review,
            match: ["worst first", "rank the findings", "order by severity",
                    "嚴重的放前面", "依嚴重度排序"],
            description: "Order surviving findings worst-first so the first one read is the one that matters.",
            examples: ["Correctness and security above maintainability.",
                       "Ordering is done after filtering, never instead of it."],
            backends: [
                .claude: "Rank the findings that survive filtering worst-first, correctness and security "
                    + "before maintainability. Rank after filtering, never as a substitute for it.",
                .codex: "Order surviving findings worst-first.",
            ],
            zhHant: "通過篩選的問題依嚴重度由重到輕排列，正確性與安全先於可維護性。排序是在篩選之後，不能取代篩選。",
            source: "anthropics/claude-code code-review plugin — validated issues only, ranked output"
        ),
    ]
}
