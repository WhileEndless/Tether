import Foundation

public extension String {
    /// Quotes a string for the remote login shell. Single quotes, with `'` and `\` escaped outside
    /// them (`'\''` and `'\\'`): POSIX shells, fish and csh/tcsh all read the same text — fish treats
    /// `\'` inside single quotes as an escape, which would otherwise let a file name end the quoting.
    var shellQuoted: String {
        if !isEmpty, allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_./=:@%+,".contains($0)) }) {
            return self
        }
        var out = "'"
        for c in self {
            switch c {
            case "'": out += "'\\''"
            case "\\": out += "'\\\\'"
            default: out.append(c)
            }
        }
        return out + "'"
    }
}

public extension String {
    /// Quoted for PowerShell: single quotes, a quote inside doubled ('it''s').
    var powerShellQuoted: String {
        if !isEmpty, allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_./\\:".contains($0)) }) { return self }
        // PowerShell also takes the typographic single quotes (‘ ’ ‚ ‛) as quotes.
        var out = "'"
        for c in self {
            out.append(c)
            if "'\u{2018}\u{2019}\u{201A}\u{201B}".contains(c) { out.append(c) }
        }
        return out + "'"
    }
}
