import Foundation
import FlowTranslateCore

/// Runs a dictated transcript through the repair model and hands back the tidied
/// text.
///
/// One driver, two callers — the Prompt tab's 整理 button and the ⌃⌥Space hotkey.
/// A repair pass that behaves differently depending on which button started it is
/// a feature with two answers.
///
/// The strategy is one generation over the whole passage, with the per-sentence
/// loop kept as the fallback. See `TranscriptRepairPrompt` for why one pass is
/// better than a call per sentence, and `PassageRepairGate` for what stops it
/// running away.
@MainActor
struct TranscriptTidier {

    /// What a pass did, in enough detail to tell the user.
    ///
    /// Reported rather than collapsed, because "the model had nothing to fix" and
    /// "every repair was thrown away by the safety gate" look identical from the
    /// outside — which is how a gate rejecting everything could stay invisible.
    struct Report {
        var text: String
        /// Chunks the one-pass repair accepted.
        var passagesRepaired = 0
        /// Chunks that fell back to the per-sentence loop, and why.
        var fallbacks: [PassageRepairGate.Rejection] = []
        /// Sentences the fallback loop changed.
        var sentencesRepaired = 0
        /// Sentences the fallback loop's gate rejected.
        var sentenceRejections: [PromptRepairGate.Rejection] = []
        /// True when nothing reached the model at all.
        var modelSilent = false
        /// Chunks the model read and returned unchanged.
        var passagesUnchanged = 0

        var changedAnything: Bool { passagesRepaired > 0 || sentencesRepaired > 0 }

        /// A one-line summary for the log, so what happened is a fact on disk
        /// rather than something to be inferred from the absence of a message.
        var summary: String {
            if modelSilent { return "model-silent" }
            var parts: [String] = []
            if passagesRepaired > 0 { parts.append("repaired=\(passagesRepaired)") }
            if passagesUnchanged > 0 { parts.append("unchanged=\(passagesUnchanged)") }
            if !fallbacks.isEmpty { parts.append("fallback=\(fallbacks.map(\.rawValue).joined(separator: ","))") }
            if sentencesRepaired > 0 { parts.append("sentences=\(sentencesRepaired)") }
            if !sentenceRejections.isEmpty {
                parts.append("rejected=\(sentenceRejections.map(\.rawValue).joined(separator: ","))")
            }
            return parts.isEmpty ? "no-op" : parts.joined(separator: " ")
        }

        /// Which characters actually changed, as `舊→新` pairs.
        ///
        /// Length alone cannot answer the question this feature exists for: a
        /// homophone swap is exactly length-preserving (城市碼→程式碼 is 3→3), so
        /// `in=54 out=54 repaired=1` is equally consistent with "fixed the term"
        /// and "changed a comma". Aligning the two strings says which.
        ///
        /// Only positions that differ are logged, never the passage — the point
        /// is to see whether the repair did its job, not to record what was said.
        func changes(from original: String) -> String {
            var before = Array(original), after = Array(text)
            guard before != after else { return "identical" }

            // Trim the common prefix and suffix, then report the span between.
            //
            // The first version compared position by position, which is only
            // valid when nothing shifts — and a repair that deletes a space or
            // adds a full stop shifts everything after it by one. A real repair
            // that changed two characters was reported as twelve, in a chain
            // where each character "became" its neighbour:
            // `少→不 不→尊 尊→的 的→，`. That is an artifact of the comparison, not
            // of the repair, and it made the log unreadable exactly when it was
            // being read most carefully.
            var head = 0
            while head < before.count, head < after.count, before[head] == after[head] {
                head += 1
            }
            before.removeFirst(head)
            after.removeFirst(head)
            var tail = 0
            while tail < before.count, tail < after.count,
                  before[before.count - 1 - tail] == after[after.count - 1 - tail] {
                tail += 1
            }
            before.removeLast(tail)
            after.removeLast(tail)
            return "\(String(before))→\(String(after)) @\(head)"
        }
    }

    /// Progress, 0…1, for a UI that cannot show a sentence counter any more.
    typealias ProgressHandler = @MainActor (Double) -> Void

    let repairer: PromptTextRepairer
    let prepareModel: (@MainActor () async -> String?)?

    /// Repair `text`, preserving its line structure.
    ///
    /// `mergesSelfCorrections` is what makes this different from a spell-check:
    /// with it on, "訂在週二兩點，啊不對，改成週三十點" comes back as Wednesday
    /// only. It is the one case where the pass is allowed to delete something the
    /// speaker said, and `PassageRepairGate` bounds how much.
    func tidy(
        _ text: String,
        origin: PromptInputOrigin,
        mergesSelfCorrections: Bool,
        onProgress: ProgressHandler? = nil
    ) async -> Report {
        let chunks = PassageChunker.chunks(text)
        guard !chunks.isEmpty else { return Report(text: text) }
        // Progress only ever moves forward. Each streamed count arrives on its
        // own hop to the MainActor, so two can land out of order and the bar
        // would visibly go backwards.
        let furthest = ProgressFloor()

        var report = Report(text: text)
        var repairedChunks: [String] = []

        for (index, chunk) in chunks.enumerated() {
            if Task.isCancelled { return Report(text: text) }
            // Each chunk owns its slice of the bar, so a two-chunk dictation does
            // not restart the progress at zero halfway through.
            let base = Double(index) / Double(chunks.count)
            let span = 1.0 / Double(chunks.count)
            let budget = max(1, TokenEstimator.estimate(chunk.text))

            let outcome = await repairer.repairPassage(
                chunk.text, origin: origin, mergesSelfCorrections: mergesSelfCorrections,
                onProgress: { produced in
                    Task { @MainActor in
                        let fraction = min(1, Double(produced) / Double(budget))
                        if let value = furthest.advance(to: base + span * fraction) {
                            onProgress?(value)
                        }
                    }
                },
                prepareModel: prepareModel
            )

            switch outcome {
            case let .repaired(fixed):
                repairedChunks.append(fixed)
                report.passagesRepaired += 1
            case .unchanged:
                // Counted, not silent. This is the one outcome that produced no
                // report entry at all, so "the model ran and found nothing to
                // fix" and "the model never ran" were indistinguishable — from
                // the HUD, from the logs, and from the code by anything short of
                // reading every branch.
                repairedChunks.append(chunk.text)
                report.passagesUnchanged += 1
            case .modelSilent:
                // The model never ran — an unloaded host or a failed prepare.
                // Falling back would spend N more failed calls to learn the same
                // thing, so the chunk is kept as dictated.
                //
                // And so is every chunk after it. The reason is host-wide, not
                // per-chunk: continuing meant chunks 2…N each called
                // `prepareModel` again, each of which can retry a multi-gigabyte
                // load and burn another slot of the consecutive-failure budget,
                // while the progress bar marched through four identical failures
                // for an answer already known at chunk one.
                report.modelSilent = true
                repairedChunks.append(chunk.text)
                repairedChunks.append(
                    contentsOf: chunks[(index + 1)...].map(\.text)
                )
                report.text = PassageChunker.rejoin(repairedChunks, chunks: chunks)
                return report
            case let .rejected(reason):
                // The one-pass result was not safe to use. The per-sentence loop
                // is slower and cannot merge a self-correction, but it is gated
                // one sentence at a time, so a single bad sentence costs that
                // sentence rather than the whole passage.
                report.fallbacks.append(reason)
                let fallback = await tidyPerSentence(chunk.text, origin: origin, report: &report)
                repairedChunks.append(fallback)
            }
            if let value = furthest.advance(to: base + span) { onProgress?(value) }
        }

        guard !Task.isCancelled else { return Report(text: text) }
        // Rejoined with the separators the chunker recorded, so untouched text
        // comes back byte-for-byte.
        report.text = PassageChunker.rejoin(repairedChunks, chunks: chunks)
        return report
    }

    /// Monotone, and throttled: `set(_:)` resizes an `NSPanel`, and a stride of
    /// eight tokens over a seven-hundred-token passage is ninety resizes for a
    /// number nobody can read changing that fast.
    @MainActor
    private final class ProgressFloor {
        private var value = 0.0
        func advance(to next: Double) -> Double? {
            guard next >= value + 0.02 || next >= 1 else { return nil }
            value = next
            return next
        }
    }

    /// The original loop, unchanged in behaviour and now reached only on a
    /// rejection.
    private func tidyPerSentence(
        _ text: String, origin: PromptInputOrigin, report: inout Report
    ) async -> String {
        let outline = RequestOutline(text)
        let sentences = outline.sentences
        guard !sentences.isEmpty else { return text }

        var repaired: [String] = []
        for (index, sentence) in sentences.enumerated() {
            if Task.isCancelled { return text }
            let context = Array(sentences[max(0, index - 2)..<index])
            switch await repairer.repair(
                sentence, origin: origin, context: context, prepareModel: prepareModel
            ) {
            case let .repaired(fixed):
                repaired.append(fixed)
                report.sentencesRepaired += 1
            case let .rejected(reason):
                repaired.append(sentence)
                report.sentenceRejections.append(reason)
            case .unchanged, .skipped, .modelSilent:
                repaired.append(sentence)
            }
        }
        return outline.rejoined(with: repaired)
    }
}
