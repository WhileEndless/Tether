import Foundation

public extension String {
    /// Quotes a string for POSIX shells using single quotes.
    var shellQuoted: String {
        if !isEmpty, allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_./=:@%+,".contains($0)) }) {
            return self
        }
        return "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
