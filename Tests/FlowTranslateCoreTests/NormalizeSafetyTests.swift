import Foundation
import Testing
@testable import FlowTranslateCore

/// `normalize` was the last stage and ran unguarded, undoing at the very end the
/// span protection every earlier technique applies. It corrupted real paths and
/// operators at `careful` — the level documented as meaning-preserving.
@Suite("Normalization never corrupts code")
struct NormalizeSafetyTests {

    private func careful(_ text: String) -> String {
        LexicalCompressor.compress(
            text, level: .careful, profile: .balanced, language: .english
        )
    }

    @Test("relative paths keep both dots")
    func parentRelativePathsSurvive() {
        // `../shared/config` and `./shared/config` are different directories.
        #expect(careful("Do not touch ../shared/config").contains("../shared/config"))
        #expect(LexicalCompressor.normalize("see ../../lib/util.h").contains("../../lib/util.h"))
    }

    @Test("qualified names keep their separators")
    func qualifiedNamesSurvive() {
        #expect(careful("Keep std::string as the return type").contains("std::string"))
        #expect(LexicalCompressor.normalize("use crate::net::Client").contains("crate::net::Client"))
    }

    @Test("range operators survive")
    func rangeOperatorsSurvive() {
        #expect(careful("Use the range 0..<5").contains("0..<5"))
        #expect(LexicalCompressor.normalize("iterate 1...10").contains("1...10"))
    }

    /// The rules still have to do their job on ordinary prose.
    @Test("prose punctuation is still tidied")
    func proseIsStillNormalized() {
        #expect(LexicalCompressor.normalize("Add retry ,  then test .") == "Add retry, then test.")
        #expect(LexicalCompressor.normalize("Wait!!! Really??") == "Wait! Really?")
    }

    /// `"that is"` is a demonstrative far more often than a gloss, and the
    /// rewrite fired on constraints.
    @Test("demonstratives are not rewritten to i.e.")
    func demonstrativesSurvive() {
        let output = careful("That is the only file that is safe to edit")
        #expect(!output.lowercased().contains("i.e."))
        #expect(output.contains("only file"))
    }

    @Test("unambiguous abbreviations still apply")
    func realAbbreviationsStillApply() {
        let output = careful("Do this in order to fix the bug, for example the retry path")
        #expect(output.contains("e.g."))
        #expect(!output.lowercased().contains("in order to"))
    }
}
