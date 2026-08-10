import XCTest
@testable import FlowTranslateCore

/// The picker used to offer "原句不動" and "改寫成完整規則" as separate modes.
/// They rendered the same bytes for every prompt the app could show, so switching
/// between them looked like a broken control. These pin the merged behaviour.
final class SymbolModeMergeTests: XCTestCase {

    private func render(_ ir: PromptIR, _ mode: PromptSymbolMode) -> PromptArtifact {
        PromptRenderer.render(ir, options: .init(
            kind: .prompt, language: .english, symbolMode: mode,
            rulebook: PromptStdlib.all, syncedSymbols: []
        ))
    }

    func testKeepMyWordingStillResolvesSymbolsTheModelEmitted() {
        // A prompt must never ship a bare identifier its reader cannot resolve,
        // whichever mode produced it.
        let ir = PromptIR(goal: "Add a retry to Uploader.swift", constraints: ["NO_DEPS"])
        let content = render(ir, .off).content
        XCTAssertFalse(content.contains("NO_DEPS"), content)
        XCTAssertTrue(content.lowercased().contains("depend"), content)
    }

    func testKeepMyWordingLeavesProseAlone() {
        let ir = PromptIR(goal: "Add a retry", constraints: ["don't add new dependencies"])
        XCTAssertTrue(render(ir, .off).content.contains("don't add new dependencies"))
    }

    func testAnUnsyncedProjectDowngradesToWrittenOutConstraints() {
        // The safety net: bare symbols were asked for, nothing defines them, so
        // the constraints are written out instead of shipped as identifiers.
        let ir = PromptIR(goal: "Add a retry", constraints: ["NO_DEPS"])
        let artifact = render(ir, .symbolsAssumeRulebook)
        XCTAssertFalse(artifact.content.contains("NO_DEPS"), artifact.content)
        XCTAssertEqual(artifact.unresolvedSymbols, ["NO_DEPS"])
    }

    func testThePickerOffersThreeModes() {
        XCTAssertEqual(PromptSymbolMode.allCases.count, 3)
        XCTAssertFalse(PromptSymbolMode.allCases.contains { $0.rawValue == "expandInline" })
    }

    func testTheRetiredModeDecodesToKeepMyWording() {
        // Someone who chose it before it was removed must land on what they were
        // actually getting — not on the app default, which is bare symbols.
        let decoded = try? JSONDecoder().decode(
            PromptSymbolMode.self, from: Data("\"expandInline\"".utf8)
        )
        XCTAssertEqual(decoded, .off)
    }

    func testAnUnknownModeStillThrowsSoTheDefaultApplies() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(PromptSymbolMode.self, from: Data("\"nonsense\"".utf8))
        )
    }

    func testSettingsMigrateTheRetiredMode() {
        let json = Data(#"{"promptSymbolMode":"expandInline"}"#.utf8)
        let settings = try? JSONDecoder().decode(CaptionSettings.self, from: json)
        XCTAssertEqual(settings?.promptSymbolMode, .off)
    }
}
