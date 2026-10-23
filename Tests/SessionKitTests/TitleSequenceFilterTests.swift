import Testing
@testable import SessionKit

@Suite struct TitleSequenceFilterTests {
    func b(_ s: String) -> [UInt8] { Array(s.utf8) }

    @Test func stripsScreenTitleAndReportsIt() {
        var f = TitleSequenceFilter()
        let r = f.filter(b("\u{1b}kls -la\u{1b}\\\r\nfile1  file2\r\n"))
        #expect(r.output == b("\r\nfile1  file2\r\n"))
        #expect(r.title == "ls -la")
    }

    @Test func keepsOtherEscapes() {
        var f = TitleSequenceFilter()
        let input = b("\u{1b}[31mred\u{1b}[0m \u{1b}]0;title\u{07}")
        #expect(f.filter(input).output == input)
    }

    @Test func handlesSplitSequences() {
        var f = TitleSequenceFilter()
        #expect(f.filter(b("a\u{1b}")).output == b("a"))
        #expect(f.filter(b("kvi")).output == [])
        let r = f.filter(b("m\u{1b}\\b"))
        #expect(r.output == b("b"))
        #expect(r.title == "vim")
        #expect(f.filter(b("\u{1b}")).output == [])
        #expect(f.filter(b("[A")).output == b("\u{1b}[A"))
    }
}
