import Foundation

/// The A-not-A question, which is built out of a negation and is not one.
///
/// Chinese asks yes/no questions by repeating the verb around 不 or 沒:
/// 是不是, 要不要, 可不可以, 有沒有, 行不行. The 不 is grammar — the sentence forbids
/// nothing — but every negation check in this codebase is a substring search for
/// 不 / 沒 / 別, so all of them read those forms as prohibitions.
///
/// The consequence was silent and total: a dictated Chinese question tidied into
/// a statement — "我們是不是可以加上重試" → "我們可以加上重試" — was rejected as
/// `negationLost`, so the repair was thrown away and the raw transcript came
/// back. Any dictation containing an A-not-A form could not be tidied at all, and
/// those forms are how people actually ask for things out loud.
///
/// Detection is structural rather than a word list: the pattern is a character
/// repeated on both sides of 不 (or 沒), which no prohibition has.
public enum ChineseQuestionForms {

    /// `text` with A-not-A question forms removed.
    ///
    /// Removed rather than rewritten because every caller is asking "is there a
    /// prohibition in here?", and the answer must not depend on a form that is
    /// asking a question.
    public static func stripped(from text: String) -> String {
        let characters = Array(text)
        guard characters.count >= 3 else { return text }

        var result = ""
        var index = 0
        while index < characters.count {
            if index + 2 < characters.count,
               isPivot(characters[index + 1]),
               characters[index] == characters[index + 2],
               TokenEstimator.isCJK(characters[index]) {
                // 可不可以 and 是不是: the two-character verb repeats around the
                // pivot as well (可不可, 以…), which the single-character rule
                // above already covers one step at a time.
                index += 3
                continue
            }
            result.append(characters[index])
            index += 1
        }
        return result
    }

    /// Whether `text` contains an A-not-A question form.
    public static func contains(in text: String) -> Bool {
        stripped(from: text).count != text.count
    }

    /// The characters an A-not-A form is built around.
    ///
    /// 沒 belongs here for 有沒有; 別 does not, because 別 has no A-not-A form —
    /// it is a prohibition wherever it appears.
    static func isPivot(_ character: Character) -> Bool {
        character == "不" || character == "沒"
    }
}
