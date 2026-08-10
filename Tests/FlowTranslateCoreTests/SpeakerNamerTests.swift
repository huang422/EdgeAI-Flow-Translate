import Foundation
import Testing
@testable import FlowTranslateCore

/// `Speaker 1` tells you nothing and reads as an error when the count is wrong.
/// A name is easier to hold across a meeting and easier to correct afterwards.
@Suite("Speaker naming")
struct SpeakerNamerTests {

    /// Always takes the first available option, so a test can assert on an exact
    /// sequence instead of on a property of a random draw.
    private func deterministic() -> SpeakerNamer { SpeakerNamer(randomSource: { _ in 0 }) }

    @Test("a name is a model and a fruit")
    func namesCombineBothPools() {
        var namer = deterministic()
        let name = namer.name(for: "1")
        #expect(SpeakerNamer.models.contains(name.model))
        #expect(SpeakerNamer.fruits.contains(name.fruit))
        #expect(name.full == "\(name.model) \(name.fruit)")
    }

    /// The identity is the diarizer's, not the order of appearance, so a speaker
    /// who says nothing for ten minutes comes back with the name they had.
    @Test("the same speaker keeps its name")
    func namesAreStable() {
        var namer = deterministic()
        let first = namer.name(for: "2")
        _ = namer.name(for: "3")
        #expect(namer.name(for: "2") == first)
    }

    /// Stricter than "no repeated pair", and deliberately: the caption band shows
    /// the model half alone, so that half has to identify the speaker by itself.
    @Test("ten speakers get ten distinct models and ten distinct fruits")
    func bothHalvesAreDrawnWithoutReplacement() {
        var namer = SpeakerNamer()
        let names = (1...10).map { namer.name(for: "\($0)") }
        #expect(Set(names.map(\.model)).count == 10)
        #expect(Set(names.map(\.fruit)).count == 10)
        #expect(names.allSatisfy { $0.modelIsUnique })
        #expect(names.allSatisfy { $0.short == $0.model })
    }

    @Test("past the pools, numbering resumes")
    func overflowIsNumbered() {
        var namer = SpeakerNamer()
        let names = (1...13).map { namer.name(for: "\($0)") }
        #expect(names[10].full == "Speaker 11")
        #expect(names[12].full == "Speaker 13")
        // A numbered speaker shows its whole label in the band; "Speaker" alone
        // would name every one of them.
        #expect(names[10].short == "Speaker 11")
        #expect(Set(names.map(\.full)).count == 13)
    }

    @Test("a meeting starts with a fresh cast")
    func resetForgetsEverything() {
        var namer = deterministic()
        let before = namer.name(for: "1")
        namer.reset()
        #expect(namer.name(for: "9") == before)
    }

    /// The overlay reserves this column on every row, so it is sized from the
    /// widest name the generator can produce. If a name could escape the list the
    /// column measures, it would be truncated on screen.
    @Test("every producible name is in the list the UI measures")
    func measurableNamesCoverTheGenerator() {
        var namer = SpeakerNamer()
        for index in 1...10 {
            let name = namer.name(for: "\(index)")
            #expect(SpeakerNamer.allFullNames.contains(name.full))
            #expect(SpeakerNamer.allShortNames.contains(name.short))
        }
    }

    @Test("blank and duplicate ids do not mint extra speakers")
    func handlesMessyIdentifiers() {
        var namer = deterministic()
        let first = namer.name(for: " 1 ")
        #expect(namer.name(for: "1") == first)
    }
}

/// Two symptoms, opposite corrections: two people reported as four wants a
/// looser threshold, five people collapsing into two wants a tighter one. One
/// constant cannot serve both, which is why this is a setting.
@Suite("Diarization sensitivity")
struct DiarizationSensitivityTests {

    @Test("the dial is ordered, and balanced matches the library's own default")
    func thresholdsAreOrdered() {
        #expect(DiarizationSensitivity.split.clusteringThreshold
            < DiarizationSensitivity.balanced.clusteringThreshold)
        #expect(DiarizationSensitivity.balanced.clusteringThreshold
            < DiarizationSensitivity.merge.clusteringThreshold)
        // FluidAudio derives the speaker-assignment threshold as `× 1.2`, and
        // `SpeakerManager` documents 0.65 as its default. The old 0.7 produced
        // 0.84 — 29% looser than recommended, which is what let five voices
        // collapse into two.
        let assignment = DiarizationSensitivity.balanced.clusteringThreshold * 1.2
        #expect(abs(assignment - 0.66) < 0.01)
    }

    @Test("an unknown stored value decodes to balanced")
    func decodesLeniently() throws {
        let json = Data(#"{"diarizationSensitivity":"aggressive"}"#.utf8)
        let settings = try JSONDecoder().decode(CaptionSettings.self, from: json)
        let sensitivity = settings.diarizationSensitivity
        #expect(sensitivity == .balanced)
    }
}

/// The tolerant decode handled an *absent* key but threw on a *present*
/// unrecognised one — and a throw fails the whole object, resetting every
/// setting the user has. One renamed case or one downgraded build away the whole
/// time.
@Suite("Settings survive an unrecognised enum value")
struct LenientEnumDecodeTests {

    private func decode(_ json: String) throws -> CaptionSettings {
        try JSONDecoder().decode(CaptionSettings.self, from: Data(json.utf8))
    }

    @Test("one bad value costs that field, not the whole object")
    func oneBadValueCostsOneField() throws {
        let settings = try decode("""
        {"overlayFontSize": 19, "secondLanguage": "klingon", "scenario": "podcast",
         "promptSymbolMode": "telepathy", "translationEngine": "carrier-pigeon"}
        """)
        // The unrecognised fields fell back…
        #expect(settings.secondLanguage == CaptionSettings.default.secondLanguage)
        #expect(settings.scenario == CaptionSettings.default.scenario)
        #expect(settings.promptSymbolMode == CaptionSettings.default.promptSymbolMode)
        #expect(settings.translationEngine == CaptionSettings.default.translationEngine)
        // …and everything else the user had set survived.
        #expect(settings.overlayFontSize == 19)
    }

    @Test("a recognised value still decodes")
    func goodValuesStillWork() throws {
        let settings = try decode(#"{"scenario":"video","diarizationSensitivity":"split"}"#)
        #expect(settings.scenario == .video)
        #expect(settings.diarizationSensitivity == .split)
    }

    /// A set goes one step further than a scalar: an unrecognised *element* would
    /// fail the whole set, taking the categories the user really did switch off
    /// with it.
    @Test("an unknown rule category is dropped, the known ones are kept")
    func unknownSetElementIsDropped() throws {
        let settings = try decode(#"{"promptRuleCategoriesOff":["testing","astrology","git"]}"#)
        #expect(settings.promptRuleCategoriesOff == [.testing, .git])
    }

    @Test("an absent key still falls back")
    func absentKeysFallBack() throws {
        let settings = try decode("{}")
        #expect(settings == CaptionSettings.default)
    }
}

/// Two modes was a false choice: the gap between raw recognizer output and a
/// fully structured agent prompt is most of what people dictate — a message, a
/// commit body, a note.
@Suite("Hotkey insert modes")
struct QuickInsertModeTests {

    @Test("three modes, and only one of them skips the model")
    func modeShape() {
        #expect(PromptQuickInsertMode.allCases.count == 3)
        #expect(PromptQuickInsertMode.compiledPrompt.needsLanguageModel)
        #expect(PromptQuickInsertMode.tidiedTranscript.needsLanguageModel)
        #expect(!PromptQuickInsertMode.rawTranscript.needsLanguageModel)
    }

    /// The HUD panel is 320 pt wide and the three buttons share one row with the
    /// shortcut hint and the drag handle, so the labels have to stay short.
    @Test("every label fits the panel")
    func labelsAreShort() {
        for mode in PromptQuickInsertMode.allCases {
            #expect(mode.shortName.count <= 7, "\(mode.shortName)")
            #expect(!mode.displayName.isEmpty)
            #expect(!mode.explanation.isEmpty)
        }
    }

    @Test("an unknown stored mode falls back rather than failing the settings")
    func decodesLeniently() throws {
        let settings = try JSONDecoder().decode(
            CaptionSettings.self,
            from: Data(#"{"promptQuickInsertMode":"telepathy","overlayFontSize":19}"#.utf8)
        )
        #expect(settings.promptQuickInsertMode == CaptionSettings.default.promptQuickInsertMode)
        #expect(settings.overlayFontSize == 19)
    }
}

/// The wrapped form both speaker columns render.
///
/// A one-line name has to reserve its full width on every row of the caption
/// band, including the rows with no speaker, and the band only has 600 pt of
/// caption to spend. Stacking the halves needs the wider half — measured at
/// 54 pt against 95 for the whole name — and abbreviates nothing.
@Suite struct SpeakerNameWrappingTests {

    @Test func aGeneratedNameWrapsAtTheJoin() {
        let name = SpeakerName(model: "Claude", fruit: "Mango")
        #expect(name.wrapped == "Claude\nMango")
    }

    @Test func aNumberedSpeakerWrapsToo() {
        let name = SpeakerName(model: "Speaker", fruit: "11", modelIsUnique: false)
        #expect(name.wrapped == "Speaker\n11")
    }

    /// Restored transcript lines arrive as plain strings, not as `SpeakerName`.
    @Test func aPlainLabelWraps() {
        #expect(SpeakerName.wrapping("DeepSeek Orange") == "DeepSeek\nOrange")
    }

    @Test func aLabelWithNoSpaceIsUnchanged() {
        #expect(SpeakerName.wrapping("Claude") == "Claude")
        #expect(SpeakerName.wrapping("") == "")
    }

    /// Splitting at the last space, so a stray space cannot orphan the fruit.
    @Test func theSplitIsAtTheLastSpace() {
        #expect(SpeakerName.wrapping("Speaker 8 8") == "Speaker 8\n8")
    }

    /// Every wrapped line the generator can produce must be covered by the
    /// candidates the column was measured against — otherwise the column is sized
    /// for names that do not occur and not for one that does.
    ///
    /// Numbers are covered by a stand-in rather than enumerated: past ten
    /// speakers the halves are `Speaker` and a running count, and `88` is the
    /// widest two digits. Beyond ninety-nine speakers on one source the count
    /// grows a third digit and outruns the stand-in — the column then widens for
    /// that row instead of cutting the number, which is why both speaker columns
    /// use `minWidth` rather than a fixed width.
    @Test func everyHalfIsAMeasuredCandidate() {
        var namer = SpeakerNamer()
        for index in 0..<12 {
            let name = namer.name(for: "speaker\(index)")
            for half in name.wrapped.split(separator: "\n").map(String.init) {
                let covered = SpeakerNamer.allNameHalves.contains(half)
                    || (half.allSatisfy(\.isNumber) && half.count <= 2)
                #expect(covered, "\(half)")
            }
        }
    }
}
