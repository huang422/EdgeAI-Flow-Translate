import Foundation

/// Whether the compiled prompt came back in the language that was asked for.
///
/// The language is applied at **compile** time, not at render time: the renderer
/// has no translator, so it can restate the rulebook's own wording and the tool's
/// own sentences in either language, but the goal, context and steps are prose
/// the model wrote. Switching the picker re-compiles for exactly that reason.
///
/// What nothing checked is whether the model obeyed. A 4-bit 4B model handed a
/// Chinese request and told "write every value in English" frequently answers in
/// Chinese anyway, and the result is a prompt whose tags and constraints are
/// English while its task and context are not — which reads as the setting being
/// ignored rather than as the model failing.
///
/// This only *reports*. Converting the text here would be a second, unguarded
/// translation pass over content the user is about to send to an agent, and a
/// wrong translation is worse than a visible mismatch: the target language is
/// enforced by the prompt and the model, not by a post-processing converter.
public enum PromptLanguageCheck {

    /// The sections whose language the model chose, in the order they render.
    /// Constraints and acceptance criteria are excluded — they are routinely
    /// symbols or rulebook wording, so their language says nothing about what
    /// the model did.
    static func modelWrittenText(_ ir: PromptIR) -> String {
        ([ir.question, ir.goal] + ir.steps + ir.context)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `text` with the tokens that belong to no language removed.
    ///
    /// Paths, identifiers, versions and numbers are the same in an English brief
    /// and a Chinese one, and a prompt is full of them. Measured raw, the single
    /// context line "Sources/Uploader.swift 在 5xx 會失敗" reads as majority
    /// Latin — twenty-two letters of file path against six Chinese characters —
    /// so a wholly Chinese prompt looked like an English one.
    static func prose(in text: String) -> String {
        text.split(whereSeparator: \.isWhitespace)
            .filter { token in
                !token.contains("/") && !token.contains("_")
                    && !token.contains(where: \.isNumber)
                    // A dotted token is a path or a member reference; a sentence
                    // full stop is attached to a word, not standing in one.
                    && !token.dropLast().contains(".")
            }
            .joined(separator: " ")
    }

    /// Whether `ir`'s prose is in a different language from `expected`.
    ///
    /// A prompt is not flagged for *containing* Chinese — an English brief
    /// quoting a Chinese error message is correct — only for being mostly the
    /// wrong language once the code-shaped tokens are set aside.
    public static func mismatches(_ ir: PromptIR, expected: PromptOutputLanguage) -> Bool {
        let body = prose(in: modelWrittenText(ir))
        // Too little prose to judge. A three-word goal that is mostly a file
        // path is not evidence of anything.
        guard body.count >= 8 else { return false }
        let isCJK = TokenEstimator.isCJKDominant(body)
        switch expected {
        case .english: return isCJK
        case .traditionalChinese: return !isCJK
        }
    }
}
