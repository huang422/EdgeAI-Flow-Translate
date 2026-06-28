import Testing
@testable import FlowTranslateCore

@Suite struct BasicTextCleanerTests {
    @Test func removesFillers() {
        let cleaner = BasicTextCleaner()
        let out = cleaner.cleanup("so um I think uh this is you know good")
        #expect(!out.lowercased().contains(" um "))
        #expect(!out.lowercased().contains(" uh "))
        #expect(!out.lowercased().contains("you know"))
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
}
