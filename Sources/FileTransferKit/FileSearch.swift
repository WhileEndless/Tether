import Foundation
import SSHTransport

/// What to look for in a folder and the folders below it (the file manager's search).
public struct FileSearchQuery: Equatable, Sendable {
    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        /// Names containing the text (any case).
        case name
        /// Names matching a pattern: `*.log`, `report-202?.pdf`, `[ab]*` (any case).
        case pattern
        /// Files containing the text (any case; files up to 20 MB).
        case content

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .name: "Name Contains"
            case .pattern: "Name Matches Pattern"
            case .content: "File Contains Text"
            }
        }
    }

    public var text: String
    public var mode: Mode
    /// Also hidden files and folders (names starting with a dot, and what is inside such folders).
    public var includeHidden: Bool

    public init(text: String, mode: Mode = .name, includeHidden: Bool = false) {
        self.text = text
        self.mode = mode
        self.includeHidden = includeHidden
    }

    /// The pattern a POSIX `find -iname` gets: the text taken literally for a name search.
    var posixPattern: String {
        switch mode {
        case .name: "*" + text.map { "*?[\\".contains($0) ? "\\\($0)" : String($0) }.joined() + "*"
        case .pattern, .content: text
        }
    }

    /// The pattern PowerShell's `-like` gets (its escape character is the backtick).
    var windowsPattern: String {
        switch mode {
        case .name: "*" + text.map { "*?[]`".contains($0) ? "`\($0)" : String($0) }.joined() + "*"
        case .pattern, .content: text
        }
    }
}

/// What a search found: the folder it started in (as the server names it), the matches (paths
/// below it), and whether there were more than were taken.
public struct FileSearchResult: Sendable {
    public var directory: String
    public var files: [RemoteFile]
    public var truncated: Bool
}

extension RemoteFileSystem {
    /// The most matches one search returns (more are only counted as "more").
    public static let searchLimit = 1000

    /// Prints the resolved folder, then the matches in the listing's format with paths relative to
    /// it. Pseudo file systems (/proc, /sys, /dev, /run) are skipped when searching from `/`;
    /// hidden folders are not entered unless asked. Stops at the limit (the pipe closes and the
    /// search ends). GNU find prints details itself; elsewhere (BusyBox, BSD) stat gives them.
    /// Arguments: folder, mode, POSIX pattern, (the Windows pattern), hidden (1/0), limit.
    static let searchScript = #"""
export LC_ALL=C
T=$(printf '\t')
cd -- "$1" 2>/dev/null || { echo "Cannot open directory: $1" >&2; exit 1; }
pwd
mode=$2 pat=$3 hidden=$5 max=$(($6 + 1))
search() {
  if [ "$(pwd)" = / ]; then
    if [ "$hidden" = 1 ]; then
      find . \( -path ./proc -o -path ./sys -o -path ./dev -o -path ./run \) -prune -o "$@"
    else
      find . \( -path ./proc -o -path ./sys -o -path ./dev -o -path ./run -o \( -name '.*' ! -name . \) \) -prune -o "$@"
    fi
  elif [ "$hidden" = 1 ]; then
    find . "$@"
  else
    find . \( -name '.*' ! -name . \) -prune -o "$@"
  fi
}
details() {
  if stat -c %s . >/dev/null 2>&1; then
    while IFS= read -r f; do stat -c "%F${T}%a${T}%U${T}%G${T}%s${T}%Y${T}${T}%n" -- "$f" 2>/dev/null; done
  else
    while IFS= read -r f; do stat -f "%HT${T}%Lp${T}%Su${T}%Sg${T}%z${T}%m${T}%Y${T}%N" -- "$f" 2>/dev/null; done
  fi
}
if [ "$mode" = content ]; then
  search -type f -size -40960 -print 2>/dev/null | tr '\n' '\0' | xargs -0 grep -l -i -F -e "$pat" -- 2>/dev/null | head -n "$max" | details
elif find . -maxdepth 0 -printf '' >/dev/null 2>&1; then
  search ! -path . -iname "$pat" -printf '%y\t%m\t%u\t%g\t%s\t%T@\t%l\t%P\n' 2>/dev/null | head -n "$max"
else
  search ! -path . -iname "$pat" -print 2>/dev/null | head -n "$max" | details
fi
exit 0
"""#

    /// Searches `directory` and the folders below it. Cancelling the calling task stops the
    /// search on the server. Large trees take a while: up to two minutes.
    public func search(_ query: FileSearchQuery, in directory: String, limit: Int = RemoteFileSystem.searchLimit) async throws -> FileSearchResult {
        let text = try await executor.output(RemoteScript(Self.searchScript, windows: WindowsFileScripts.search),
                                             arguments: [directory, query.mode.rawValue, query.posixPattern, query.windowsPattern,
                                                         query.includeHidden ? "1" : "0", String(limit)],
                                             timeout: 120, purpose: "files", stopOnCancel: true)
        return Self.parseSearch(text, limit: limit)
    }

    static func parseSearch(_ text: String, limit: Int) -> FileSearchResult {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return FileSearchResult(directory: "/", files: [], truncated: false) }
        let dir = lines.removeFirst()
        var files = lines.compactMap { entry($0, in: dir) }
        let truncated = files.count > limit
        if truncated { files.removeLast(files.count - limit) }
        return FileSearchResult(directory: dir, files: files, truncated: truncated)
    }
}
