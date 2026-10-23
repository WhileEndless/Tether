import Foundation
import Testing
import TetherCore
@testable import SSHTransport

@Suite struct PlatformDetectionTests {
    @Test func tellsShellsApart() {
        // sh/bash/zsh leave %OS% alone and $PSHOME is empty.
        #expect(RemotePlatform.parse(probeOutput: "TETHER:%OS%::\n") == .posix)
        // cmd.exe expands %OS% and prints the quotes and $PSHOME literally.
        #expect(RemotePlatform.parse(probeOutput: "\"TETHER:Windows_NT:$PSHOME:\"\r\n") == .windowsCmd)
        // PowerShell expands $PSHOME (a path with a drive colon) and leaves %OS%.
        #expect(RemotePlatform.parse(probeOutput: "TETHER:%OS%:C:\\Windows\\System32\\WindowsPowerShell\\v1.0:\r\n") == .windowsPowerShell)
        // Login banners before the answer are ignored; no answer at all is unknown.
        #expect(RemotePlatform.parse(probeOutput: "Welcome!\nTETHER:%OS%::\n") == .posix)
        #expect(RemotePlatform.parse(probeOutput: "") == nil)
    }
}

@Suite struct PowerShellTests {
    @Test func launcherDecodesToTheStdinReader() throws {
        let encoded = try #require(PowerShell.launcher.split(separator: " ").last)
        let data = try #require(Data(base64Encoded: String(encoded)))
        let units = stride(from: 0, to: data.count, by: 2).map { UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8 }
        #expect(String(decoding: units, as: UTF16.self) == PowerShell.launcherSource)
        // Only characters that neither cmd nor PowerShell treat specially.
        #expect(String(encoded).allSatisfy { $0.isLetter || $0.isNumber || "+/=".contains($0) })
    }

    @Test func argumentsAreQuoted() {
        #expect(PowerShell.quote("it's") == "'it''s'")
        let script = PowerShell.prepare("Write-Output $A[0]", arguments: ["C:/Users/user/O'Brien", "$(evil)"])
        #expect(script.contains("$A=@('C:/Users/user/O''Brien','$(evil)');"))
    }

    @Test func stdinCarriesTheScriptAsOneBase64Line() throws {
        let input = PowerShell.input("'hello'", arguments: [])
        let text = String(decoding: input, as: UTF8.self)
        #expect(text.hasSuffix("\n") && text.filter { $0 == "\n" }.count == 1)
        let decoded = try #require(Data(base64Encoded: String(text.dropLast())))
        #expect(String(decoding: decoded, as: UTF8.self).hasSuffix("\n'hello'"))
    }

    @Test func lineEndingsAreNormalized() {
        let crlf = Data("a\r\nb\r\n@@end\r\n".utf8)
        #expect(String(decoding: PowerShell.normalize(crlf), as: UTF8.self) == "a\nb\n@@end\n")
        // A CR that is not followed by LF stays (e.g. a progress line).
        #expect(String(decoding: PowerShell.normalize(Data("x\ry".utf8)), as: UTF8.self) == "x\ry")
    }

    @Test func windowsOnlyRunsScriptsThatHaveAWindowsVariant() throws {
        let executor = RemoteExecutor(target: .alias("win"), options: SSHOptions())
        #expect(throws: RemoteError.self) {
            _ = try executor.invocation(RemoteScript("uname"), arguments: [], platform: .windowsCmd, extra: nil)
        }
        let call = try executor.invocation(RemoteScript("uname", windows: "$PSVersionTable"), arguments: ["x"],
                                           platform: .windowsPowerShell, extra: nil)
        #expect(call.command == PowerShell.launcher)
        let posix = try executor.invocation(RemoteScript("uname"), arguments: ["a b"], platform: .posix, extra: nil)
        #expect(posix.command == "sh -s -- 'a b'")
    }
}

@Suite struct AppVersionTests {
    @Test func comparesVersions() {
        #expect(AppVersion.isNewer("0.2.1", than: "0.2.0"))
        #expect(AppVersion.isNewer("v0.10.0", than: "0.9.9"))
        #expect(AppVersion.isNewer("1.0", than: "0.9.12"))
        #expect(!AppVersion.isNewer("0.2.0", than: "0.2.0"))
        #expect(!AppVersion.isNewer("v0.2", than: "0.2.0"))
        #expect(!AppVersion.isNewer("0.1.9", than: "0.2.0"))
        #expect(!AppVersion.isNewer("garbage", than: "0.2.0"))
    }
}
