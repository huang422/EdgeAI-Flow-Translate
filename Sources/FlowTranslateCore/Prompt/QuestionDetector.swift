import Foundation

/// Decides whether a request is asking something rather than instructing.
///
/// Exists as a deterministic backstop rather than trusting the classification to
/// the model. A 4-bit 4B model asked to choose a `taskType` picks `new` for
/// almost anything, and the cost of getting this one wrong is unusually high: a
/// question compiled as a task produces a prompt telling Claude to go and build
/// something, which is not a degraded answer to the question but the opposite of
/// it — and the prompt reads perfectly well, so nothing downstream catches it.
///
/// The signals are the ones a question actually carries. Punctuation first,
/// because it is unambiguous in both scripts; then interrogatives, because
/// dictation frequently loses the question mark; then the advisory verbs that
/// ask for a recommendation without being grammatically interrogative
/// ("建議我要用哪個", "which should I use").
public enum QuestionDetector {

    /// Whether `request` is asking for an answer rather than a change.
    public static func isQuestion(_ request: String) -> Bool {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // A request that ends in a question mark is a question, in either width.
        if let last = trimmed.last, last == "?" || last == "？" { return true }

        let lowered = trimmed.lowercased()

        // An imperative that merely *contains* a question mid-way is still an
        // instruction: "fix the parser and tell me why it broke" is work to do.
        // Only a leading interrogative counts.
        if openers.contains(where: { lowered.hasPrefix($0) }) { return true }
        // Chinese has no fixed word order for this, so its markers are matched
        // anywhere. They are specific enough not to appear in an instruction:
        // 為什麼 / 該不該 / 哪一個 do not turn up in "改成 XML 標籤輸出".
        if chineseMarkers.contains(where: { trimmed.contains($0) }) { return true }
        // The A-not-A form — 是不是, 要不要, 會不會, 需不需要 — asked structurally
        // rather than from a list. A hand-written list can only hold the handful
        // somebody thought of, and every verb missing from it is a dictated
        // question compiled as a task.
        return ChineseQuestionForms.contains(in: trimmed)
    }

    /// English interrogatives and advice-seeking openers.
    ///
    /// Prefix-matched, and each carries its trailing space so `whats` inside a
    /// larger word cannot trigger. `how` is deliberately absent on its own —
    /// "how about we ship it" is a question but "however" and, more importantly,
    /// "how to build X" is routinely written as an instruction — so only the
    /// forms that are unambiguously interrogative are listed.
    static let openers = [
        "what ", "what's ", "whats ", "why ", "which ", "who ", "when ", "where ",
        "should i ", "should we ", "do i ", "do we ", "can i ", "can we ",
        "is it ", "are there ", "does it ", "would it ", "how do i ", "how do we ",
        "how should ", "how does ", "how can i ", "explain why ", "tell me why ",
        "help me understand ", "any idea ", "any advice ", "what would you ",
    ]

    /// Chinese interrogatives and advice-seeking phrases.
    ///
    /// Every entry is at least two characters and specific to asking. 嗎 and 呢
    /// are single characters and are deliberately absent — they attach to the end
    /// of ordinary sentences often enough that matching them would classify
    /// instructions as questions.
    ///
    /// The A-not-A forms (要不要, 能不能, 可不可以, 有沒有, 行不行, 好不好, 該不該,
    /// 值不值得) are deliberately absent: `ChineseQuestionForms` recognises that
    /// whole family structurally, and a list here could only hold the handful
    /// somebody thought of.
    ///
    /// What is added instead is the 怎麼/如何 family, **only in its modal forms**.
    /// Bare 怎麼 and bare 如何 are not here on purpose: "說明如何安裝" and "看看
    /// 怎麼改比較好" are instructions, and the cost of getting this wrong is not a
    /// worse answer but the opposite one — a task compiled as a question is never
    /// carried out. 該/要 in front makes it a question about what to do rather
    /// than an order to do it.
    static let chineseMarkers = [
        "為什麼", "為何", "怎麼會", "怎麼辦", "該怎麼", "要怎麼", "怎麼樣",
        "該如何", "要如何", "如何選", "怎麼選",
        "什麼時候", "是什麼", "有什麼", "什麼意思", "什麼差別",
        "哪一個", "哪個", "哪些", "哪裡", "該用",
        "建議我", "你建議", "你覺得", "幫我判斷", "幫我評估",
        "差別在", "差在哪", "有差嗎", "是不是應該",
    ]
}
