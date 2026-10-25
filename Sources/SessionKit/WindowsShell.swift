import Foundation
import TetherCore

/// The interactive PowerShell a Windows terminal tab runs, whatever the host's default shell.
///
/// The start script travels as `-EncodedCommand` (plain base64, so neither cmd nor PowerShell can
/// mangle it) and carries a random tag. The tag makes the shell's command line unique, which is
/// how the command running in this tab is found on the host later (`ShellAnchor.windows`): the
/// Windows console host does not pass private escape sequences through, so the shell cannot
/// simply report its pid the way the POSIX bootstrap does.
public struct WindowsShell: Sendable {
    /// The remote command for ssh.
    public let command: String
    /// A string only this shell's command line contains.
    public let tag: String

    public init(platform: RemotePlatform, directory: String?, tag: String = UUID().uuidString) {
        var script = "# tether-shell \(tag)"
        if let directory, !directory.isEmpty {
            script += "\nSet-Location -LiteralPath '" + directory.replacingOccurrences(of: "'", with: "''") + "'"
        }
        let encoded = Self.encode(script)
        self.tag = encoded
        // A PowerShell default shell starts the same PowerShell again (Windows PowerShell or
        // PowerShell 7), so the user keeps the shell they chose; cmd starts Windows PowerShell.
        let shell = platform == .windowsPowerShell ? "& (Get-Process -Id $PID).Path" : "powershell"
        command = "\(shell) -NoLogo -NoExit -EncodedCommand \(encoded)"
    }

    /// Base64 of the UTF-16LE text, as `-EncodedCommand` expects.
    static func encode(_ script: String) -> String {
        var utf16 = Data()
        for unit in script.utf16 { utf16.append(UInt8(unit & 0xff)); utf16.append(UInt8(unit >> 8)) }
        return utf16.base64EncodedString()
    }
}
