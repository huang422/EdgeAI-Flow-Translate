import Foundation
import Testing
@testable import FlowTranslateCore

/// Deletion has to be earned. Merging a self-correction is the one reason a tidy
/// pass may remove something the speaker said, so a passage with no
/// self-correction in it licenses none.
@Suite("Self-correction cues")
struct SelfCorrectionCuesTests {

    @Test("cues are found in both scripts")
    func findsCues() {
        #expect(SelfCorrectionCues.count(in: "meet Tuesday at 2, actually Wednesday at 10") == 1)
        #expect(SelfCorrectionCues.count(in: "訂在週二兩點，不對，改成週三十點") == 2)
        #expect(SelfCorrectionCues.count(in: "use uploadChunk, no wait, uploadBlock") == 1)
    }

    /// Punctuation must not hide a cue: "…two, sorry, three" is the ordinary
    /// spoken shape.
    @Test("punctuation around a cue does not hide it")
    func punctuationIsNotABoundary() {
        #expect(SelfCorrectionCues.count(in: "make it two, sorry, three") == 1)
    }

    @Test("an ordinary passage has none")
    func plainTextHasNoCues() {
        #expect(SelfCorrectionCues.count(in: "add a retry to the uploader, it fails on 5xx") == 0)
        #expect(SelfCorrectionCues.count(in: "幫我在上傳器加上重試機制，測試要過") == 0)
    }

    /// A word-bounded match, so a cue inside a longer word does not fire.
    @Test("a cue inside another word does not count")
    func noSubstringMatchesInLatin() {
        #expect(SelfCorrectionCues.count(in: "gather the rathernot files") == 0)
    }

    /// One correction is one cue, however many bare cues its compound contains.
    ///
    /// "actually no" used to score twice — once as the phrase and once for the
    /// `actually` inside it — which doubled the deletion allowance, doubled the
    /// per-cue edit bonus and took `dropAllowance` from one to two. The gate then
    /// accepted repairs that had deleted about twice what one self-correction
    /// licenses.
    @Test("a compound cue is not counted twice")
    func compoundCuesAreCountedOnce() {
        #expect(SelfCorrectionCues.count(in: "use uploadChunk, actually no, use uploadBlock") == 1)
        #expect(SelfCorrectionCues.count(in: "meet Tuesday, no actually, Wednesday") == 1)
        #expect(SelfCorrectionCues.count(in: "make it two, sorry no, three") == 1)
        // …and a genuinely separate bare cue still counts on its own.
        #expect(SelfCorrectionCues.count(in: "two, actually no, three, sorry, four") == 2)
    }

    /// The budget that the count feeds. One correction buys one merge.
    @Test("one compound cue buys one merge, not two")
    func compoundCueBudget() {
        let one = PassageRepairGate.DeletionBudget.measured(
            in: "use uploadChunk, actually no, use uploadBlock"
        )
        #expect(one.cues == 1)
        #expect(one.dropAllowance == 1)
    }

    /// With no cue the budget is tight enough to be close to the per-sentence
    /// gate; each cue buys room for one more merge.
    @Test("the budget loosens with cues and never tightens")
    func budgetIsMonotone() {
        let none = PassageRepairGate.DeletionBudget.measured(in: "add a retry to the uploader")
        let one = PassageRepairGate.DeletionBudget.measured(in: "two, actually three")
        let many = PassageRepairGate.DeletionBudget.measured(
            in: "two, actually three, sorry four, i mean five"
        )
        #expect(none.dropAllowance == 0)
        #expect(none.deletionAllowance < one.deletionAllowance)
        #expect(one.deletionAllowance < many.deletionAllowance)
        #expect(many.dropAllowance == 2)
    }
}

/// The per-sentence gate cannot be reused: merging deliberately deletes, and
/// every rule there assumes preservation. These rules invert — nothing may
/// *appear* that was not dictated, and disappearance is licensed by cues.
@Suite("Passage repair gate")
struct PassageRepairGateTests {

    private func rejection(_ original: String, _ corrected: String) -> PassageRepairGate.Rejection? {
        PassageRepairGate.rejection(original: original, corrected: corrected)
    }

    // MARK: Sanitize

    /// The one place this must not follow `PromptRepairGate.sanitize`, which
    /// keeps the first line only — here that silently truncates a five-line
    /// dictation to its first sentence.
    @Test("every line survives sanitizing")
    func sanitizeKeepsEveryLine() {
        #expect(PassageRepairGate.sanitize("one\ntwo\nthree") == "one\ntwo\nthree")
        #expect(PassageRepairGate.sanitize("整理後：one\ntwo") == "one\ntwo")
        #expect(PassageRepairGate.sanitize("```\none\ntwo\n```") == "one\ntwo")
    }

    /// A label on a later line is content — a dictated list can begin a line with
    /// "Output:".
    @Test("only a leading label is stripped")
    func labelsAreStrippedOnlyAtTheTop() {
        // The label goes; the second line, which merely looks like one, stays.
        #expect(PassageRepairGate.sanitize("Corrected:\nOutput: 3 files") == "Output: 3 files")
        #expect(PassageRepairGate.sanitize("one\nOutput: 3 files") == "one\nOutput: 3 files")
    }

    @Test("a quote pair around the whole passage is stripped")
    func wholePassageQuotesAreStripped() {
        #expect(PassageRepairGate.sanitize("「one\ntwo」") == "one\ntwo")
    }

    // MARK: Accepting a merge

    /// The reference case, in both scripts, and the clearest statement of the
    /// licensing design: the same pair is accepted with cues and rejected without.
    @Test("a cued self-correction is accepted")
    func mergesAreAccepted() {
        #expect(rejection(
            "let's meet Tuesday at 2, actually no, Wednesday at 10 works better",
            "Let's meet Wednesday at 10."
        ) == nil)
        #expect(rejection(
            "我們約禮拜二兩點，不對，改成禮拜三十點比較好",
            "我們約禮拜三十點。"
        ) == nil)
    }

    /// A restatement with no cue is indistinguishable from content loss, so it is
    /// blocked. Deliberate, and the reason the cue list is generous.
    @Test("an uncued deletion is rejected")
    func uncuedDeletionIsRejected() {
        #expect(rejection(
            "let's meet Tuesday at 2 Wednesday at 10 works better for everyone here",
            "Let's meet Wednesday at 10."
        ) != nil)
    }

    // MARK: Invention — never licensed

    @Test("an invented number is rejected however many cues there are")
    func inventedNumbersAreNeverAllowed() {
        #expect(rejection(
            "set the timeout, actually make it longer, sorry, much longer",
            "Set the timeout to 30 seconds, actually make it 60."
        ) == .numberInvented)
    }

    @Test("an invented identifier is rejected")
    func inventedIdentifiersAreNeverAllowed() {
        #expect(rejection(
            "add a retry to the uploader it fails a lot on transient errors",
            "Add a retry to RetryPolicy.swift; the uploader fails on transient errors."
        ) == .identifierInvented)
    }

    /// The one failure with no upside. Whatever the passage is pasted into will
    /// carry the inversion.
    @Test("a lost prohibition is rejected")
    func inversionIsRejected() {
        #expect(rejection(
            "add a retry to the uploader but do not add any new dependencies here",
            "Add a retry to the uploader, and add new dependencies here."
        ) == .negationLost)
    }

    // MARK: Additions

    @Test("appended lines are rejected")
    func addedLinesAreRejected() {
        #expect(rejection(
            "add a retry to the uploader, it fails on transient errors sometimes",
            "Add a retry to the uploader; it fails on transient errors.\nNote: I fixed the grammar."
        ) == .contentAdded)
    }

    /// The only rule that catches invented *prose*: a fabricated clause with no
    /// number or identifier in it is caught here or not at all, because a
    /// whole-passage edit distance moves by ~5% on one hallucinated sentence.
    @Test("a passage that grew is rejected")
    func growthIsRejected() {
        let original = "add a retry to the uploader, it fails on transient errors sometimes"
        let padded = original + " and you should also make sure the tests still pass afterwards"
        #expect(rejection(original, padded) == .lengthRatio)
    }

    // MARK: Degeneration

    /// A 4-bit model can loop, the risk rises with output length, and the
    /// repetition penalty's window cannot see a loop with a longer period.
    @Test("a repetition loop is caught")
    func loopsAreCaught() {
        let phrase = "the uploader retries on transient failures again "
        #expect(rejection(
            "add a retry to the uploader it fails on transient errors sometimes",
            String(repeating: phrase, count: 5)
        ) != nil)
        #expect(PassageRepairGate.looped(
            String(repeating: phrase, count: 5), original: "add a retry"
        ))
    }

    /// A dictation may legitimately repeat itself; only a repeat the original did
    /// not have counts.
    @Test("a repeat the speaker made is not a loop")
    func repeatedInputIsNotALoop() {
        let phrase = "the uploader retries on transient failures again "
        let said = String(repeating: phrase, count: 5)
        #expect(!PassageRepairGate.looped(said, original: said))
    }

    // MARK: Ordinary repairs

    @Test("punctuation and spelling repairs are accepted")
    func ordinaryRepairsPass() {
        #expect(rejection(
            "add a retry to teh uploader it fials on 5xx erors",
            "Add a retry to the uploader; it fails on 5xx errors."
        ) == nil)
        #expect(rejection(
            "幫我在 Sources/Uploader.swift 加上從試機制 測試藥過",
            "幫我在 Sources/Uploader.swift 加上重試機制。測試要過。"
        ) == nil)
    }

    /// Multi-line output is the normal case here and a rejection there — the
    /// clearest illustration that the two gates are not interchangeable.
    @Test("multi-line output is accepted here and rejected by the per-sentence gate")
    func theTwoGatesDisagreeOnPurpose() {
        let original = "add a retry to the uploader\nmake sure the tests pass"
        let corrected = "Add a retry to the uploader.\nMake sure the tests pass."
        #expect(rejection(original, corrected) == nil)
        #expect(PromptRepairGate.rejection(original: original, corrected: corrected) == .multiline)
    }

    @Test("meta commentary and Simplified drift are still caught")
    func inheritedChecksStillApply() {
        #expect(rejection("add a retry to the uploader now", "Here is the corrected text.") == .meta)
        #expect(rejection("加上重試機制，測試要過", "加上重试机制，测试要过。") == .simplifiedChinese)
    }

    @Test("identical text is unchanged, not a failure")
    func identityIsUnchanged() {
        #expect(rejection("add a retry to the uploader", "add a retry to the uploader") == .unchanged)
    }
}

/// One pass is the point, so chunking exists only for the dictation too long to
/// fit one. The budget is generous so that almost every dictation is one chunk.
@Suite("Passage chunking")
struct PassageChunkerTests {

    @Test("an ordinary dictation is a single chunk")
    func shortInputIsOneChunk() {
        let text = "add a retry to the uploader, it fails on transient errors, "
            + "and make sure the existing tests still pass afterwards"
        #expect(PassageChunker.chunks(text).count == 1)
    }

    @Test("blank input yields nothing")
    func blankYieldsNothing() {
        #expect(PassageChunker.chunks("").isEmpty)
        #expect(PassageChunker.chunks("   \n  ").isEmpty)
    }

    /// The property everything downstream rests on, and the one that catches the
    /// bug this type shipped with on its first draft: rejoining with a hard
    /// `"\n"` inserted line breaks the speaker never made. The hotkey transcript
    /// is a **single line** — finalized segments are joined with a space — so a
    /// long dictation came back with newlines at every sentence boundary.
    @Test("chunking and rejoining is the identity on untouched text")
    func chunksRoundTrip() {
        let inputs = [
            // The hotkey shape: one long line, no newlines anywhere.
            (1...90).map { "This is sentence number \($0) in one long run." }
                .joined(separator: " "),
            // The Prompt tab shape: many lines.
            (1...90).map { "This is line number \($0) of a dictated list." }
                .joined(separator: "\n"),
            // Mixed, with a blank line and a trailing newline.
            (1...50).map { "Line \($0). And a second sentence on it." }
                .joined(separator: "\n") + "\n\n" + String(repeating: "tail sentence. ", count: 40),
            // Short enough not to chunk at all.
            "add a retry to the uploader",
        ]
        for text in inputs {
            let chunks = PassageChunker.chunks(text)
            #expect(
                PassageChunker.rejoin(chunks.map(\.text), chunks: chunks) == text,
                "round trip failed for a \(text.count)-character input"
            )
        }
    }

    @Test("a long input really does split")
    func longInputSplits() {
        let long = (1...90).map { "This is sentence number \($0) in one long run." }
            .joined(separator: " ")
        #expect(PassageChunker.chunks(long).count > 1)
    }

    /// A dictated list has one item per line, so cutting between items keeps
    /// each chunk a complete thought — and the separator recorded is the line
    /// break, not a space.
    @Test("a line boundary is recorded as a line boundary")
    func lineBoundariesArePreserved() {
        let long = (1...90).map { "This is line number \($0) of a dictated list." }
            .joined(separator: "\n")
        let chunks = PassageChunker.chunks(long)
        #expect(chunks.dropLast().allSatisfy { $0.separator == "\n" })
        #expect(chunks.last?.separator == "")
    }

    /// A single line over budget is split at sentence boundaries rather than
    /// mid-clause — a fragment handed to the repairer is a fragment it will try
    /// to repair — and the pieces are rejoined with a space, not a newline.
    @Test("an over-long line splits at sentences and rejoins with spaces")
    func overlongLinesSplitAtSentences() {
        let line = (1...90).map { "This is sentence number \($0) in one very long run." }
            .joined(separator: " ")
        let chunks = PassageChunker.chunks(line)
        #expect(chunks.count > 1)
        #expect(chunks.dropLast().allSatisfy { $0.separator == " " })
        for chunk in chunks {
            #expect(chunk.text.hasSuffix("run."), "\(chunk.text.suffix(40))")
        }
    }

    @Test("every chunk is within budget unless one sentence exceeds it alone")
    func chunksRespectTheBudget() {
        let long = (1...90).map { "This is sentence number \($0) in one long run." }
            .joined(separator: " ")
        for chunk in PassageChunker.chunks(long) {
            #expect(TokenEstimator.estimate(chunk.text) <= PassageChunker.budget)
        }
    }
}

/// The highest-leverage string in the feature, and it had no tests at all while
/// it lived in the app target.
@Suite("Transcript repair prompt")
struct TranscriptRepairPromptTests {

    @Test("the protective rules are present in every variant")
    func protectiveRulesAlwaysPresent() {
        for origin in [PromptInputOrigin.speech, .typed, .mixed] {
            for merges in [true, false] {
                let prompt = TranscriptRepairPrompt.system(
                    origin: origin, mergesSelfCorrections: merges
                )
                #expect(prompt.contains("NEVER change or invent a number"))
                #expect(prompt.contains("NEVER add or remove a negation"))
                #expect(prompt.contains("Never translate"))
                #expect(prompt.contains("台灣正體中文"))
                #expect(prompt.contains("Keep identifiers"))
            }
        }
    }

    @Test("the self-correction rule appears only when merging is on")
    func selfCorrectionRuleIsConditional() {
        let merging = TranscriptRepairPrompt.system(origin: .speech, mergesSelfCorrections: true)
        let plain = TranscriptRepairPrompt.system(origin: .speech, mergesSelfCorrections: false)
        #expect(merging.contains("Self-corrections"))
        #expect(merging.contains("啊不對"))
        #expect(!plain.contains("Self-corrections"))
    }

    /// The wording has to be passage-scoped. "the line" is how the per-sentence
    /// prompt would silently leak in during a copy-paste, and the model would
    /// return one sentence for a whole dictation.
    @Test("the wording is about a passage, not a line")
    func wordingIsPassageScoped() {
        let prompt = TranscriptRepairPrompt.system(origin: .speech, mergesSelfCorrections: true)
        #expect(prompt.contains("passage"))
        #expect(!prompt.contains("repair one line"))
    }

    /// An example the gate would reject is teaching the model to fail, and
    /// nothing else would ever catch it.
    @Test("every worked example passes the gate")
    func examplesSurviveTheirOwnGate() {
        let pairs = [
            ("幫我在 Sources/Uploader.swift 加上從試機制\n測試藥過",
             "幫我在 Sources/Uploader.swift 加上重試機制。\n測試要過。"),
            ("add a retry to teh uploader it fials on 5xx erors",
             "Add a retry to the uploader; it fails on 5xx errors."),
            ("把會議訂在週二下午兩點 啊不對 改成週三早上十點",
             "把會議訂在週三早上十點。"),
            ("use uploadChunk for this no wait use uploadBlock",
             "Use uploadBlock for this."),
        ]
        for (original, corrected) in pairs {
            #expect(
                PassageRepairGate.rejection(original: original, corrected: corrected) == nil,
                "\(original) → \(corrected)"
            )
        }
    }

    @Test("the token cap is bounded and scales with the input")
    func tokenCapIsBounded() {
        #expect(TranscriptRepairPrompt.tokenCap(for: "hi") == 128)
        let long = String(repeating: "這是一段很長的口述內容，需要整理。", count: 200)
        #expect(TranscriptRepairPrompt.tokenCap(for: long) == 1600)
        let medium = String(repeating: "add a retry to the uploader. ", count: 20)
        let cap = TranscriptRepairPrompt.tokenCap(for: medium)
        #expect(cap > 128 && cap < 1600)
    }
}

/// The two false positives the gate shipped with on its first run, kept as
/// regressions because both would have made the headline feature fail silently
/// on the exact input it exists for.
@Suite("Merge false positives")
struct MergeFalsePositiveTests {

    /// Several cues *contain* a negation marker — "actually no", "不對". Merging
    /// removes the marker by design, so comparing the raw text rejected every
    /// successful merge as an inverted meaning.
    @Test("a cue that contains a negation is not read as a prohibition")
    func cuesAreNotProhibitions() {
        #expect(!SymbolCompressor.isNegated(
            SelfCorrectionCues.stripped(from: "meet Tuesday, actually no, Wednesday")
        ))
        #expect(!SymbolCompressor.isNegated(
            SelfCorrectionCues.stripped(from: "訂在週二，不對，改成週三")
        ))
    }

    /// …while a real prohibition still survives cue-stripping, which is the half
    /// that makes the fix safe rather than merely permissive.
    @Test("a real prohibition survives cue-stripping")
    func realProhibitionsSurvive() {
        #expect(SymbolCompressor.isNegated(
            SelfCorrectionCues.stripped(from: "add a retry but do not add new dependencies")
        ))
        #expect(SymbolCompressor.isNegated(
            SelfCorrectionCues.stripped(from: "加上重試，但不要新增套件")
        ))
    }

    /// A merge on a short passage *is* a large edit, so a flat distance budget
    /// rejects the correct answer. Cues buy edit room the way they buy deletion
    /// room.
    @Test("a short merge is not too different")
    func shortMergesClearTheEditBudget() {
        #expect(PassageRepairGate.rejection(
            original: "use uploadChunk for this no wait use uploadBlock",
            corrected: "Use uploadBlock for this."
        ) == nil)
    }

    /// And a rewrite with nothing to justify it still is.
    @Test("an unjustified rewrite is still too different")
    func rewritesAreStillRejected() {
        #expect(PassageRepairGate.rejection(
            original: "add a retry to the uploader it fails on transient errors",
            corrected: "Please implement exponential backoff in the network layer."
        ) != nil)
    }
}

/// Two helpers with the same name, the same signature and different answers used
/// to live in `PassageRepairGate` and `SelfCorrectionCues`. Both semantics are
/// still needed; they just have to be asked for by name now.
@Suite("Shared text counting")
struct TextCountingTests {

    /// Each match consumes its own characters: two adjacent cues are two
    /// corrections, not three overlapping matches of a cue that appears twice.
    @Test("matches do not overlap")
    func matchesDoNotOverlap() {
        #expect(TextCounting.nonOverlappingOccurrences(of: "aa", in: "aaaa") == 2)
        #expect(TextCounting.nonOverlappingOccurrences(of: "不對", in: "不對不對") == 2)
        #expect(TextCounting.nonOverlappingOccurrences(of: "不對", in: "這不對") == 1)
    }

    @Test("an empty needle finds nothing rather than looping")
    func emptyNeedleTerminates() {
        #expect(TextCounting.nonOverlappingOccurrences(of: "", in: "anything") == 0)
    }

    @Test("content characters ignore punctuation and spaces")
    func contentCharactersCountLettersAndDigits() {
        #expect(TextCounting.contentCharacters("OK.") == 2)
        #expect(TextCounting.contentCharacters("……！") == 0)
        #expect(TextCounting.contentCharacters("我知道了") == 4)
        // v · 2 · c o s t s · 3 0 0 — the space is not content, the digits are.
        #expect(TextCounting.contentCharacters("v2 costs 300") == 10)
    }
}

/// `looped` was rewritten onto a rolling hash to stop allocating a 24-character
/// `String` per position. The answers must be identical to the string-keyed
/// version it replaced.
@Suite("Loop detection")
struct LoopDetectionTests {

    private let phrase = "把重試機制加到上傳器並且設定逾時三十秒鐘好嗎"

    @Test("a runaway repeat is caught")
    func catchesARunaway() {
        let looping = String(repeating: phrase, count: 6)
        #expect(PassageRepairGate.looped(looping, original: phrase))
    }

    /// The other half of the rule: a passage that genuinely repeated itself is
    /// not a model failure.
    @Test("a repeat the speaker actually made is not a loop")
    func allowsARepeatTheOriginalHad() {
        let repeated = String(repeating: phrase, count: 6)
        #expect(!PassageRepairGate.looped(repeated, original: repeated))
    }

    @Test("ordinary prose is not a loop")
    func prosePasses() {
        let text = String(repeating: "Add a retry to the uploader so transient failures recover. ", count: 3)
            + "Then make sure the existing tests still pass before opening a pull request."
        #expect(!PassageRepairGate.looped(text, original: text))
    }

    @Test("text shorter than one window cannot loop")
    func tooShortToLoop() {
        #expect(!PassageRepairGate.looped("short", original: "short"))
    }

    /// A degenerate single-character repeat is the worst case for the hash and
    /// the one most likely to go quadratic; it must still terminate promptly.
    @Test("a degenerate single-character run terminates")
    func degenerateRunTerminates() {
        let run = String(repeating: "啊", count: 4_000)
        #expect(PassageRepairGate.looped(run, original: "啊"))
    }
}

/// The repair prompt has to *ask* for the thing it is for.
///
/// Every rule in it started out protective — what the model must not change —
/// and the one instruction that makes a tidy pass better than a spellcheck is
/// the opposite kind: read the whole passage and let what it is about decide
/// between spellings that sound identical. A recognizer picks the commonest
/// spelling of a sound, so its mistakes are real words that fit the sound and
/// not the sentence, and only context can tell them apart.
@Suite("The repair prompt asks for context")
struct RepairPromptContextTests {

    private var speech: String {
        TranscriptRepairPrompt.system(origin: .speech, mergesSelfCorrections: true)
    }

    @Test("the speech error model explains why context is the evidence")
    func speechErrorModelNamesContext() {
        let text = TranscriptRepairPrompt.errorModel(for: .speech)
        #expect(text.contains("homophones"))
        #expect(text.lowercased().contains("context") || text.contains("ABOUT"))
    }

    /// …and only for speech. Told to hunt for mis-hearings in typed text, a model
    /// finds them whether or not they are there.
    @Test("typed input is not told to expect mis-hearings")
    func typedErrorModelIsDifferent() {
        let typed = TranscriptRepairPrompt.errorModel(for: .typed)
        #expect(typed.contains("NOT mis-hearings"))
        #expect(!typed.contains("homophones"))
    }

    @Test("the rules carry a whole-passage context rule")
    func rulesAskForWholePassageContext() {
        #expect(speech.contains("Use the whole passage as context"))
    }

    /// A worked example in each script, because the rule is abstract and the
    /// model is 4B: 復本/副本 and reeds/reads are both real words that only the
    /// surrounding sentence can decide.
    @Test("both scripts get a homophone example decided by context")
    func homophoneExamplesExist() {
        #expect(speech.contains("復本"))
        #expect(speech.contains("副本"))
        #expect(speech.contains("reeds"))
    }

    /// The protective rules are what let the context rule be safe to give.
    @Test(arguments: ["NEVER change or invent a number", "NEVER add or remove a negation",
                      "Never translate", "台灣正體中文"])
    func protectiveRulesSurvive(_ rule: String) {
        #expect(speech.contains(rule), "\(rule)")
    }
}

/// Writing a spoken Chinese numeral as a digit is a normalization, and the gate
/// used to reject the whole passage for it.
///
/// Seen in the field as `fallback=numberInvented sentences=1` on a 26-character
/// dictation with no digit in it anywhere: the speaker said a number in
/// characters, the model wrote it in digits, and `digitRuns` — which counts
/// positional digits only, so that 幫我看一下 is not read as containing a number —
/// saw a run appear from nowhere.
@Suite("Chinese numerals written as digits")
struct ChineseNumeralNormalizationTests {

    @Test(arguments: [("三", 3), ("十", 10), ("三十", 30), ("三十二", 32),
                      ("兩百", 200), ("一千", 1000), ("二萬", 20000)])
    func readsTheValue(_ text: String, _ expected: Int) {
        #expect(ChineseNumerals.value(of: text) == expected, "\(text)")
    }

    @Test func findsEveryNumberInASentence() {
        #expect(ChineseNumerals.values(in: "timeout 設成三十秒，重試三次")
            == Set([30, 3]))
    }

    @Test func textWithoutNumeralsNamesNothing() {
        #expect(ChineseNumerals.values(in: "幫我看這段程式碼").isEmpty)
    }

    /// The repair the gate was throwing away.
    @Test func normalizingASpokenNumberIsAccepted() {
        let spoken = "timeout 設成三十秒 然後 重試三次"
        let tidied = "timeout 設成 30 秒，重試 3 次。"
        #expect(PassageRepairGate.rejection(original: spoken, corrected: tidied)
            != .numberInvented,
            "\(String(describing: PassageRepairGate.rejection(original: spoken, corrected: tidied)))")
    }

    /// And an actual invention is still caught: 30 was said, 50 was not.
    ///
    /// Long enough that the length check does not answer first — a two-word
    /// passage is rejected on its deletion budget before the digits are looked
    /// at, which says nothing about this rule either way.
    @Test func aDifferentNumberIsStillRejected() {
        let spoken = "把上傳器的 timeout 設成三十秒 然後 重試的次數也調整一下 這樣比較保險"
        let invented = "把上傳器的 timeout 設成 50 秒，然後重試的次數也調整一下，這樣比較保險。"
        #expect(PassageRepairGate.rejection(original: spoken, corrected: invented)
            == .numberInvented)
    }

    /// The filter itself, without the other rules in the way.
    @Test func onlyUnspokenValuesSurviveTheFilter() {
        let spoken = "設成三十秒"
        #expect(TranscriptCorrectionGate
            .digitsNotNamedInChinese(of: "設成 30 秒", saidIn: spoken).isEmpty)
        #expect(TranscriptCorrectionGate
            .digitsNotNamedInChinese(of: "設成 50 秒", saidIn: spoken) == ["50"])
    }

    /// Chinese numerals stay out of the *dropped* accounting, which is what made
    /// Chinese repairs possible at all.
    @Test func droppingAChineseNumeralIsNotADroppedNumber() {
        #expect(TranscriptCorrectionGate.digitRuns("幫我看一下這段程式碼").isEmpty)
    }

}

