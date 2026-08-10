import Foundation

/// Reads the numbers Chinese writes in characters.
///
/// Exists for one job: telling a **normalization** apart from an **invention**.
/// The repair gates hold digits sacred — a number in the output that was not in
/// the input means the model made a quantity up, and the whole passage is
/// thrown away for it. `digitRuns` counts only positional digits, deliberately:
/// 一 二 三 十 百 carry a numeric value in Unicode, and counting them made every
/// ordinary Chinese sentence look full of numbers, so 幫我看**一**下 could not be
/// repaired at all.
///
/// That leaves a gap this closes. A speaker says 三十秒 and the model writes
/// "30 秒" — correct, and the kind of tidying the pass exists for — but the
/// original has no digit runs and the repair has one, so it reads as invented
/// and the passage is rejected. Seen in the field as
/// `fallback=numberInvented` on a passage with no digit in it anywhere.
///
/// Only the *invented* side consults this. Chinese numerals stay out of the
/// "numbers were dropped" accounting, because that is the check whose
/// false positives made Chinese repairs impossible in the first place.
public enum ChineseNumerals {

    /// Every number `text` names in Chinese numerals, as values.
    public static func values(in text: String) -> Set<Int> {
        var found: Set<Int> = []
        var run = ""
        for ch in text {
            if digits[ch] != nil || units[ch] != nil {
                run.append(ch)
            } else {
                if let value = value(of: run) { found.insert(value) }
                run = ""
            }
        }
        if let value = value(of: run) { found.insert(value) }
        return found
    }

    /// The value of one run of Chinese numerals, or nil if it names none.
    ///
    /// The ordinary place-value reading: digits accumulate, a unit multiplies
    /// what came before it, and 萬 closes a section. A bare unit means one of it
    /// — 十 is ten, not zero — which is why the digit defaults to 1 there.
    static func value(of run: String) -> Int? {
        guard !run.isEmpty else { return nil }
        var total = 0
        var section = 0
        var digit = 0
        var sawDigit = false
        for ch in run {
            if let d = digits[ch] {
                digit = d
                sawDigit = true
            } else if let unit = units[ch] {
                if unit >= 10_000 {
                    total += (section + digit) * unit
                    section = 0
                } else {
                    section += (sawDigit ? digit : 1) * unit
                }
                digit = 0
                sawDigit = false
            }
        }
        let value = total + section + digit
        return value > 0 ? value : (run.contains("〇") || run.contains("零") ? 0 : nil)
    }

    static let digits: [Character: Int] = [
        "〇": 0, "零": 0, "一": 1, "二": 2, "兩": 2, "两": 2, "三": 3, "四": 4,
        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
    ]

    static let units: [Character: Int] = ["十": 10, "百": 100, "千": 1_000, "萬": 10_000, "万": 10_000]
}
