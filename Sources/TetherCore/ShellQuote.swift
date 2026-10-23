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
