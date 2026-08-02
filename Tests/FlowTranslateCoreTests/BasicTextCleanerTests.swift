import Testing
@testable import FlowTranslateCore

@Suite struct BasicTextCleanerTests {
    @Test func removesFillers() {
        let cleaner = BasicTextCleaner()
        let out = cleaner.cleanup("so um I think uh this is erm good")
        #expect(!out.lowercased().contains(" um "))
        #expect(!out.lowercased().contains(" uh "))
        #expect(!out.lowercased().contains(" erm "))
        #expect(out.contains("I think"))
        #expect(out.contains("good"))
    }

    @Test func compressesWhitespace() {
        let cleaner = BasicTextCleaner(fillers: [])
        #expect(cleaner.cleanup("a    b   c") == "a b c")
    }

    @Test func doesNotBreakWords() {
        let cleaner = BasicTextCleaner()
        let out = cleaner.cleanup("the drum is loud")
        #expect(out.contains("drum"))
    }

    /// Regression (M8): multi-word discourse phrases carry meaning and must
    /// never be stripped — "What kind of car" used to become "What car".
    @Test func keepsMeaningfulPhrases() {
        let cleaner = BasicTextCleaner()
        #expect(cleaner.cleanup("What kind of car do you want") == "What kind of car do you want")
        #expect(cleaner.cleanup("Do you know him") == "Do you know him")
        #expect(cleaner.cleanup("I mean it this time") == "I mean it this time")
        #expect(cleaner.cleanup("It is sort of a test") == "It is sort of a test")
    }

    @Test func removesAdjacentDuplicateFillers() {
        let cleaner = BasicTextCleaner()
        let out = cleaner.cleanup("well um um uh let's start")
        #expect(!out.lowercased().contains(" um "))
        #expect(!out.lowercased().contains(" uh "))
        #expect(out.contains("let's start"))
    }
}
