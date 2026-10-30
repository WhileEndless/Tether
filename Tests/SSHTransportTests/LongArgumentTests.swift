import Foundation
import Testing
import TestSupport
@testable import SSHTransport

/// Thousands of file names for one script: the server's command line stays short (Linux refuses a
/// single argument over 128 KB) and the script still gets every name exactly.
@Suite struct LongArgumentTests {
    @Test func manyArgumentsGoInTheScript() throws {
        let names = (0..<3000).map { "name \($0) with 'quotes' and \"more\" ç😀\nnewline " + String(repeating: "x", count: 80) }
        let executor = RemoteExecutor(target: .alias("example"), options: SSHOptions())
        let call = try executor.invocation(RemoteScript(#"printf '%s\n' "$#"; for a; do printf '%s\0' "$a"; done"#),
                                           arguments: names, platform: .posix, extra: nil)
        #expect(call.command == "sh -s --", "the command line holds no names (\(call.command.utf8.count) bytes)")
        // What the server's sh does with it.
        let input = String(decoding: call.input, as: UTF8.self)
        let r = BoundedProcess.run("/bin/sh", ["-s", "--"], input: input, timeout: 30)
        let lines = r.output.split(separator: "\n", maxSplits: 1)
        #expect(lines.first == "3000")
        let got = r.output.drop(while: { $0 != "\n" }).dropFirst().split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
        #expect(got == names, "every name arrives as it was")
        // A few short ones stay on the command line, as before.
        let short = try executor.invocation(RemoteScript("true"), arguments: ["a b", "c"], platform: .posix, extra: nil)
        #expect(short.command == "sh -s -- 'a b' c")
    }
}
