import Testing
@testable import FlowTranslateCore

@Suite struct BasicS2TWPConverterTests {
    private let converter = BasicS2TWPConverter()

    @Test func convertsTaiwanPhrases() {
        #expect(converter.s2twp("软件") == "軟體")
        #expect(converter.s2twp("网络") == "網路")
        #expect(converter.s2twp("视频会议") == "影片會議")
    }

    @Test func convertsCharacters() {
        #expect(converter.s2twp("这个国家") == "這個國家")
    }

    @Test func leavesTraditionalUntouched() {
        #expect(converter.s2twp("這是繁體中文") == "這是繁體中文")
    }
}
