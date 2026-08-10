import Foundation

/// Recovers a `PromptIR` from whatever a local model actually returned.
///
/// A 4-bit 4B model asked for strict JSON usually complies, but not always: it
/// may wrap the object in a ``` fence, prepend "Here is the JSON:", or emit a
/// short preamble object before the real one. Constrained decoding is not
/// available on this path, so the parser is where that slack gets absorbed —
/// the same tolerant-parsing posture `MLXMeetingSummarizer` already takes for
/// summaries.
public enum PromptIRParser {

    /// Best-effort parse. Returns `nil` only when nothing in `raw` decodes to an
    /// IR with a goal; callers fall back to `salvage(from:)`.
    public static func parse(_ raw: String) -> PromptIR? {
        // Largest object first: a preamble like `{"note": "..."}` is small, and
        // the real payload is the big one.
        for candidate in jsonObjects(in: raw).sorted(by: { $0.count > $1.count }) {
            if let ir = decode(candidate) { return ir }
        }
        return nil
    }

    static func decode(_ json: String) -> PromptIR? {
        guard let data = json.data(using: .utf8),
              let ir = try? JSONDecoder().decode(PromptIR.self, from: data),
              ir.isActionable
        else { return nil }
        return ir
    }

    /// Rescue the part of a truncated object that did arrive.
    ///
    /// When generation stops at the token cap the object never closes, so
    /// `jsonObjects` finds nothing and everything the model produced — the goal,
    /// the context, most of the constraints — is thrown away in favour of a
    /// skeleton rebuilt from the raw request. That is the worst available
    /// outcome: the expensive part already ran, and its result is discarded
    /// because of the last half-written field.
    ///
    /// So instead: cut back to the last point where the JSON was complete, close
    /// the brackets that were still open there, and decode that. Only the
    /// field being written when the budget ran out is lost, which is what
    /// "truncated" should have cost all along.
    ///
    /// This is why the cap can also be generous rather than defensive — a
    /// request too long for one pass now degrades by one bullet instead of
    /// needing to be split in two.
    public static func recoverTruncated(_ raw: String) -> PromptIR? {
        guard let repaired = closingTruncatedObject(in: raw) else { return nil }
        return decode(repaired)
    }

    /// The longest prefix of the unterminated object that is still valid JSON,
    /// with its open brackets closed.
    ///
    /// Cut points are the commas and closing brackets outside string literals:
    /// everything before a comma is a complete element, at every nesting depth.
    /// A half-written string is never closed and guessed at — a goal cut in the
    /// middle reads as a finished instruction, and a wrong instruction that looks
    /// deliberate is worse than a missing one.
    static func closingTruncatedObject(in raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{") else { return nil }

        var stack: [Character] = []
        var inString = false
        var escaped = false
        // The best cut so far: where to slice, and what was still open there.
        var cut: (index: String.Index, closers: [Character])?

        var index = start
        while index < raw.endIndex {
            let character = raw[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else {
                switch character {
                case "\"": inString = true
                case "{": stack.append("}")
                case "[": stack.append("]")
                case "}", "]":
                    guard !stack.isEmpty else { return nil }
                    stack.removeLast()
                    // A complete value just ended. Cutting straight after it is
                    // safe as long as something is still open to close.
                    if !stack.isEmpty {
                        cut = (raw.index(after: index), stack)
                    }
                case ",":
                    // Everything before the comma is complete. Cut before it, so
                    // no trailing comma is left behind.
                    if !stack.isEmpty { cut = (index, stack) }
                default: break
                }
            }
            index = raw.index(after: index)
        }

        // Already balanced — not truncated, and not this function's problem.
        guard !stack.isEmpty, let cut else { return nil }
        return String(raw[start..<cut.index]) + String(cut.closers.reversed())
    }

    /// Last resort when no JSON survived: treat the cleaned request as the goal
    /// so the user still gets a rendered prompt instead of an error. Better a
    /// thin result they can edit than a dead end.
    public static func salvage(from request: String) -> PromptIR {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return PromptIR() }

        let sentences = SentenceSplitter.split(trimmed)
        let goal = sentences.first ?? trimmed
        let rest = Array(sentences.dropFirst())
        // Split the question out from the work, sentence by sentence, rather than
        // deciding the whole request is one or the other. Salvage runs when there
        // is no model answer at all — offline, truncated, or a request too short
        // to compile — and a request that both asks and instructs is common
        // enough that collapsing it either way loses half of what was said.
        let questions = sentences.filter(QuestionDetector.isQuestion)
        let work = sentences.filter { !QuestionDetector.isQuestion($0) }
        guard !questions.isEmpty else {
            return PromptIR(goal: goal, context: PromptIR.normalize(rest))
        }
        return PromptIR(
            goal: work.first ?? "",
            question: questions.joined(separator: " "),
            context: PromptIR.normalize(Array(work.dropFirst()))
        )
    }

    /// Recover a question the model turned into an instruction.
    ///
    /// The model is asked to fill `question` and mostly will not: a 4-bit 4B
    /// model has been shown four task-shaped examples and reaches for `goal`.
    /// Getting it wrong is not a degraded answer but an inverted one — the prompt
    /// tells Claude to go and build something in reply to "where should the files
    /// go?" — so the deterministic signal corrects it.
    ///
    /// Only ever *adds* a question, and only when the model produced none. A
    /// model that did fill `question` is left alone, including when it also
    /// filled `goal`: that pairing is a request which asks and instructs, which
    /// is what the two fields exist to represent.
    ///
    /// **Per sentence, not per request.** The first version assigned the entire
    /// request to `question` and blanked `goal`, because `isQuestion` had said
    /// yes to the request as a whole. But it says yes to "為何字幕會跳動？順便把
    /// finalize 修好" on the strength of its first clause, so the instruction in
    /// the second was relabelled as part of the question and the work was lost.
    /// Splitting first keeps each half where it belongs.
    public static func classifying(_ ir: PromptIR, from request: String) -> PromptIR {
        guard !ir.asksAQuestion else { return ir }
        let sentences = SentenceSplitter.split(request).filter { !$0.isEmpty }
        let asked = sentences.filter(QuestionDetector.isQuestion)

        guard !asked.isEmpty else {
            // No individual sentence reads as a question. The request as a whole
            // still might — one question split across a boundary — and in that
            // case the request's own words are the more faithful record of what
            // was asked than the imperative the model rewrote it into.
            guard QuestionDetector.isQuestion(request) else { return ir }
            var result = ir
            result.question = request
            result.goal = ""
            return result
        }

        var result = ir
        result.question = asked.joined(separator: " ")
        // Blank the goal only when *nothing* in the request asked for work.
        // Otherwise the model's imperative describes the part that did, and is a
        // better record of it than the raw sentence would be.
        if asked.count == sentences.count { result.goal = "" }
        return result
    }

    /// Whether generation stopped in the middle of the JSON object.
    ///
    /// A run that hit its token cap leaves an opened `{` that never closes, so
    /// `jsonObjects` finds nothing and the caller falls back to salvage. That
    /// fallback works, but reporting it as "the model's output was unparseable"
    /// sends the user looking for a model problem when the actual cause is a
    /// budget this code set — and the fix (a longer cap, or a shorter request)
    /// is completely different.
    public static func looksTruncated(_ raw: String) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for character in raw {
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}", depth > 0 {
                depth -= 1
            }
        }
        return depth > 0 || inString
    }

    /// Every balanced top-level `{…}` in `raw`, ignoring braces inside strings.
    ///
    /// String-aware because a path or a regex in a value ("a\"}b") would
    /// otherwise close the object early and truncate the parse.
    static func jsonObjects(in raw: String) -> [String] {
        var objects: [String] = []
        var depth = 0
        var inString = false
        var escaped = false
        var start: String.Index?

        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if character == "}", depth > 0 {
                depth -= 1
                if depth == 0, let opened = start {
                    objects.append(String(raw[opened...index]))
                    start = nil
                }
            }
            index = raw.index(after: index)
        }
        return objects
    }
}
