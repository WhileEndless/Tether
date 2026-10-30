import Foundation
import Testing
@testable import TerminalText

/// Image transmissions are taken only with their data inline; other kinds are changed to one the
/// terminal does not take — also split across chunks — with the length kept and nothing else changed.
struct ImageSequenceFilterTests {
    private let esc = "\u{1b}"

    private func run(_ chunks: [String]) -> String {
        var f = ImageSequenceFilter()
        var out: [UInt8] = []
        for c in chunks { out += f.filter(Array(c.utf8)[...]) }
        out += f.flush()
        return String(decoding: out, as: UTF8.self)
    }

    @Test func inlineImagesAndOtherSequencesPass() {
        for s in ["a\(esc)_Ga=T,f=100;iVBORw0KGgo=\(esc)\\b", "x\(esc)[1mbold\(esc)[0m\(esc)_other\(esc)\\\(esc)]0;title\u{07}y",
                  "\(esc)_Gt=d,a=T;AAAA\(esc)\\", "\(esc)_Ga=q,i=1\(esc)\\", "\(esc)_Ga=T,tt=f;x\(esc)\\", "\(esc)_Ga=T,s=4,v=4;dd==\(esc)\\"] {
            #expect(run([s]) == s)
        }
    }

    @Test func transmissionsNamingAPlaceAreChanged() {
        for t in ["f", "t", "s"] {
            #expect(run(["a\(esc)_Ga=T,t=\(t),f=100;QUJDRA==\(esc)\\b"]) == "a\(esc)_Ga=T,t=x,f=100;QUJDRA==\(esc)\\b")
            #expect(run(["\(esc)_Gt=\(t);eA==\(esc)\\"]) == "\(esc)_Gt=x;eA==\(esc)\\")
            #expect(run(["\(esc)_Ga=q,t=\(t)\(esc)\\"]) == "\(esc)_Ga=q,t=x\(esc)\\", "a query")
        }
    }

    @Test func splitAnywhereKeepsTheLength() {
        let input = "a\(esc)_Ga=T,t=f;eHk=\(esc)\\b\(esc)_Ga=T;QQ==\(esc)\\c\(esc)"
        let expected = input.replacingOccurrences(of: "t=f", with: "t=x")
        let bytes = Array(input.utf8)
        for cut in 1..<bytes.count {
            var f = ImageSequenceFilter()
            let out = Array(f.filter(bytes[..<cut])) + Array(f.filter(bytes[cut...])) + f.flush()
            #expect(String(decoding: out, as: UTF8.self) == expected, "cut at \(cut)")
        }
        #expect(ImageSequenceFilter.filtered(bytes).count == bytes.count)
        #expect(String(decoding: ImageSequenceFilter.filtered(bytes), as: UTF8.self) == expected)
    }

    @Test func plainOutputIsNotCopied() {
        var f = ImageSequenceFilter()
        let plain = Array("hello \(esc)[31mred\(esc)[0m".utf8)[...]
        #expect(f.filter(plain) == plain)
    }
}
