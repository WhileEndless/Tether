import Foundation
import TetherCore
import SSHTransport

public struct RemoteFile: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case directory, file, symlink, other
    }

    public var name: String
    public var path: String
    public var kind: Kind
    public var permissions: Int      // e.g. 0o755
    public var owner: String
    public var group: String
    public var size: Int64
    public var modified: Date
    public var linkTarget: String?

    public init(name: String, path: String, kind: Kind, permissions: Int = 0, owner: String = "", group: String = "",
                size: Int64 = 0, modified: Date = Date(timeIntervalSince1970: 0), linkTarget: String? = nil) {
        self.name = name
        self.path = path
        self.kind = kind
        self.permissions = permissions
        self.owner = owner
        self.group = group
        self.size = size
        self.modified = modified
        self.linkTarget = linkTarget
    }

    public var id: String { path }
    public var isDirectory: Bool { kind == .directory }
    public var isHidden: Bool { name.hasPrefix(".") }

    public var permissionString: String {
        let prefix: String = switch kind {
        case .directory: "d"
        case .symlink: "l"
        default: "-"
        }
        let bits = ["r", "w", "x"]
        var s = prefix
        for shift in stride(from: 6, through: 0, by: -3) {
            let v = (permissions >> shift) & 7
            for (i, b) in bits.enumerated() { s += (v & (4 >> i)) != 0 ? b : "-" }
        }
        return s
    }

    public var fileExtension: String { (name as NSString).pathExtension.lowercased() }
}

/// Lists and manipulates files on a remote host through the shared ssh connection.
public struct RemoteFileSystem: Sendable {
    public let executor: RemoteExecutor

    public init(executor: RemoteExecutor) {
        self.executor = executor
    }

    /// Prints the resolved directory, then one tab-separated line per entry:
    /// kind, octal mode, owner, group, size, mtime, link target, name.
    /// Works with GNU find, BusyBox/GNU stat and BSD (macOS) stat.
    static let listScript = #"""
export LC_ALL=C
T=$(printf '\t')
if [ -z "$1" ]; then cd || exit 1; else cd -- "$1" 2>/dev/null || { echo "Cannot open directory: $1" >&2; exit 1; }; fi
pwd
if find . -maxdepth 0 -printf '' >/dev/null 2>&1; then
  find . -mindepth 1 -maxdepth 1 -printf '%y\t%m\t%u\t%g\t%s\t%T@\t%l\t%f\n' 2>/dev/null
elif stat -c %s . >/dev/null 2>&1; then
  for f in .* *; do case "$f" in .|..) continue;; esac; [ -e "$f" ] || [ -L "$f" ] || continue
    stat -c "%F${T}%a${T}%U${T}%G${T}%s${T}%Y${T}${T}%n" -- "$f"; done
else
  for f in .* *; do case "$f" in .|..) continue;; esac; [ -e "$f" ] || [ -L "$f" ] || continue
    stat -f "%HT${T}%Lp${T}%Su${T}%Sg${T}%z${T}%m${T}%Y${T}%N" -- "$f"; done
fi
"""#

    /// Lists a directory. Pass nil for the home directory.
    public func list(_ path: String?) async throws -> (directory: String, files: [RemoteFile]) {
        let text = try await executor.output(RemoteScript(Self.listScript, windows: WindowsFileScripts.list), arguments: [path ?? ""], timeout: 30, purpose: "files")
        return Self.parseListing(text)
    }

    public static func parseListing(_ text: String) -> (directory: String, files: [RemoteFile]) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return ("/", []) }
        let dir = lines.removeFirst()
        return (dir, lines.compactMap { entry($0, in: dir) })
    }

    /// One listing line: kind, octal mode, owner, group, size, mtime, link target, then the name —
    /// or a path below `dir` (a search result: `sub/name`, also `./sub/name`).
    static func entry(_ line: String, in dir: String) -> RemoteFile? {
        let f = line.split(separator: "\t", maxSplits: 7, omittingEmptySubsequences: false).map(String.init)
        guard f.count == 8 else { return nil }
        let kind: RemoteFile.Kind
        switch f[0].lowercased() {
        case "d", "directory": kind = .directory
        case "f", "regular file", "regular empty file": kind = .file
        case "l", "symbolic link": kind = .symlink
        default: kind = .other
        }
        var relative = f[7]
        while relative.hasPrefix("./") { relative.removeFirst(2) }
        guard !relative.isEmpty, relative != "." else { return nil }
        let name = (relative as NSString).lastPathComponent
        let path = dir.hasSuffix("/") ? dir + relative : dir + "/" + relative
        return RemoteFile(name: name, path: path, kind: kind, permissions: Int(f[1], radix: 8) ?? 0,
                          owner: f[2], group: f[3], size: Int64(f[4]) ?? 0,
                          modified: Date(timeIntervalSince1970: Double(f[5]) ?? 0),
                          linkTarget: f[6].isEmpty ? nil : f[6])
    }

    /// For each wanted name, a name that does not exist yet in `directory` (and is not used by an
    /// earlier name of the same batch): `report.pdf` → `report-1.pdf`, `report-2.pdf`, …
    /// Creates the directory if needed — unless `create` is false (a folder Tether chose itself,
    /// such as the terminal's current one, which must exist: a stale one is not made anew).
    /// Never overwrites anything.
    /// - Parameter mayBeMissing: a missing folder is fine and is not made (every name is free
    ///   there): a packed upload makes it itself only once the stream has started.
    public func uniqueNames(in directory: String, for names: [String], create: Bool = true,
                            mayBeMissing: Bool = false) async throws -> [String] {
        let writable = #"[ -d "$d" ] && [ -w "$d" ] || { echo "Cannot write to $d" >&2; exit 1; }"#
        let check = mayBeMissing ? #"if [ -e "$d" ] || [ -L "$d" ]; then "# + writable + "; fi"
            : create ? #"mkdir -p -- "$d" 2>/dev/null; "# + writable
            : #"[ -d "$d" ] || { echo "No such folder: $d" >&2; exit 1; }; "# + writable
        let script = Self.uniqueNamesScript.replacingOccurrences(of: "MAKE", with: check)
        let platform = await executor.resolvedPlatform()
        // Thousands of names take a while on a slow host: the time allowed grows with them.
        // Each name with the parts a number goes between (worked out here, one rule for the Mac,
        // POSIX and Windows hosts, and short enough for the 255-byte limit).
        let parts = names.flatMap { name -> [String] in
            let (base, ext) = LocalFiles.numberedParts(name, separator: "-")
            return [name, base, ext]
        }
        let out = try await executor.output(RemoteScript(script, windows: WindowsFileScripts.uniqueNames),
                                            arguments: [directory] + parts, timeout: 30 + Double(names.count) / 50, purpose: "files")
        var result = out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // The Windows variant first prints the folder it resolved (e.g. ~ or /tmp).
        if platform.isWindows, !result.isEmpty { result.removeFirst() }
        guard result.count == names.count else { throw RemoteError("Could not choose file names in \(directory).") }
        return result
    }

    /// Free names (`MAKE` is replaced by how the folder is made and checked). Names chosen earlier in
    /// the batch are kept in one string and matched with `case` (no program started per name); a
    /// link to nowhere counts as taken (writing there would follow it).
    static let uniqueNamesScript = #"""
d="$1"; shift
MAKE
nl='
'
taken="$nl"
# name, the part before the number, the extension after it — for each wanted name.
while [ "$#" -ge 3 ]; do
  n="$1"; base="$2"; ext="$3"; shift 3
  c="$n"; i=1
  while [ -e "$d/$c" ] || [ -L "$d/$c" ] || case "$taken" in *"$nl$c$nl"*) true ;; *) false ;; esac; do
    c="$base-$i$ext"; i=$((i+1))
  done
  taken="$taken$c$nl"
  printf '%s\n' "$c"
done
"""#

    /// Counts the files under the given remote paths and their total size, to plan a download.
    /// GNU find counts and sums in one walk; elsewhere `find | wc` and `du`.
    public func measure(_ paths: [String], timeout: TimeInterval = 120) async throws -> TransferSize {
        let out = try await executor.output(RemoteScript(Self.measureScript, windows: WindowsFileScripts.measure), arguments: paths,
                                            timeout: timeout, purpose: "files")
        let parts = out.split(whereSeparator: \.isWhitespace).compactMap { Int64($0) }
        guard parts.count == 2 else { throw RemoteError("Could not measure \(paths.count) item(s).") }
        return TransferSize(files: Int(parts[0]), bytes: parts[1] * 1024)
    }

    /// Prints "<files> <kilobytes>".
    static let measureScript = #"""
files=0; kb=0
if find . -maxdepth 0 -printf '' >/dev/null 2>&1; then
  for p in "$@"; do
    r=$(find "$p" ! -type d -printf '%s\n' 2>/dev/null | awk '{ n++; s += $1 } END { printf "%d %d\n", n, s / 1024 }')
    files=$((files + ${r% *})); kb=$((kb + ${r#* }))
  done
else
  for p in "$@"; do
    if [ -d "$p" ]; then n=$(find "$p" ! -type d 2>/dev/null | wc -l); else n=1; fi
    k=$(du -sk -- "$p" 2>/dev/null | cut -f1)
    files=$((files + n)); kb=$((kb + ${k:-0}))
  done
fi
echo "$files $kb"
"""#

    /// Removes one of Tether's staging folders (`.tether-transfer-…`) from a folder — nothing else:
    /// any other name, a name with a slash or a link is refused.
    static let stagingCleanupScript = #"""
d="$1"; t="$2"
case "$t" in .tether-transfer-*) ;; *) exit 2 ;; esac
case "$t" in */*) exit 2 ;; esac
[ -d "$d/$t" ] && [ ! -L "$d/$t" ] || exit 0
rm -rf -- "$d/$t"
"""#

    /// Removes a packed upload's staging folder left on the server (normally the unpacking script
    /// removes it itself). POSIX hosts only: packed transfers never go to Windows.
    public func removeStaging(_ name: String, in directory: String) async {
        guard LocalFiles.isStagingName(name) else { return }
        _ = await executor.run(RemoteScript(Self.stagingCleanupScript, windows: nil), arguments: [directory, name],
                               timeout: 20, purpose: "files")
    }

    // MARK: Bulk operations (all refuse to overwrite existing files)

    /// Moves items into `directory`. Items whose name already exists there are skipped and reported.
    @discardableResult
    public func move(_ paths: [String], to directory: String) async throws -> [String] {
        try await transfer(paths, to: directory, command: "mv")
    }

    /// Copies items (recursively) into `directory`. Existing names are skipped and reported.
    @discardableResult
    public func copy(_ paths: [String], to directory: String) async throws -> [String] {
        try await transfer(paths, to: directory, command: "cp -R")
    }

    private func transfer(_ paths: [String], to directory: String, command: String) async throws -> [String] {
        let script = #"""
d="$1"; shift
[ -d "$d" ] || { echo "No such folder: $d" >&2; exit 1; }
for p in "$@"; do
  n=$(basename -- "$p")
  if [ -e "$d/$n" ]; then echo "$n"; continue; fi
  CMD -- "$p" "$d/$n" || exit 1
done
"""#.replacingOccurrences(of: "CMD", with: command)
        let windowsCommand = command == "mv" ? "Move-Item" : "Copy-Item"
        let platform = await executor.resolvedPlatform()
        let out = try await executor.output(RemoteScript(script, windows: WindowsFileScripts.transfer),
                                            arguments: (platform.isWindows ? [windowsCommand] : []) + [directory] + paths,
                                            timeout: 600, purpose: "files")
        return out.split(separator: "\n").map(String.init)   // names skipped because they exist
    }

    /// Copies (or moves) items into `directory` under free names — `name-1.ext` when the name is
    /// taken, also when pasting into the folder they came from — and returns the names used. A
    /// folder is never copied into itself; a move within its own folder does nothing. Never
    /// overwrites anything.
    public func copyWithFreeNames(_ paths: [String], to directory: String, move: Bool = false) async throws -> [String] {
        let out = try await executor.output(RemoteScript(Self.pasteScript, windows: WindowsFileScripts.paste),
                                            arguments: [move ? "1" : "0", directory] + paths,
                                            timeout: 1800, purpose: "files")
        let names = out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard names.count == paths.count else { throw RemoteError("Could not paste into \(directory).") }
        return names
    }

    static let pasteScript = #"""
m="$1"; d="$2"; shift 2
[ -d "$d" ] && [ -w "$d" ] || { echo "Cannot write to $d" >&2; exit 1; }
nl='
'
taken="$nl"
for p in "$@"; do
  p="${p%/}"; n="${p##*/}"
  [ -e "$p" ] || [ -L "$p" ] || { echo "$n is no longer there" >&2; exit 1; }
  if [ "$m" = 1 ] && [ "${p%/*}" = "${d%/}" ]; then printf '%s\n' "$n"; continue; fi
  case "${d%/}/" in "$p"/*) echo "$n cannot be put into itself" >&2; exit 1 ;; esac
  base="$n"; ext=""
  case "$n" in
    .*.*|[!.]*.*) base="${n%.*}"; ext=".${n##*.}" ;;
  esac
  c="$n"; i=1
  while [ -e "$d/$c" ] || [ -L "$d/$c" ] || case "$taken" in *"$nl$c$nl"*) true ;; *) false ;; esac; do
    c="$base-$i$ext"; i=$((i+1))
  done
  taken="$taken$c$nl"
  if [ "$m" = 1 ]; then mv -- "$p" "$d/$c" || exit 1; else cp -R -p -- "$p" "$d/$c" || exit 1; fi
  printf '%s\n' "$c"
done
"""#

    /// chmod with a numeric (755) or symbolic (u+x) mode. Paths are absolute, so no `--` is needed
    /// (BSD chmod does not accept it after the mode).
    public func setPermissions(_ paths: [String], mode: String, recursive: Bool) async throws {
        _ = try await executor.output(script: #"m="$1"; r="$2"; shift 2; if [ "$r" = 1 ]; then chmod -R "$m" "$@"; else chmod "$m" "$@"; fi"#,
                                      arguments: [mode, recursive ? "1" : "0"] + paths, timeout: 120, purpose: "files")
    }

    /// Where `directory` really is on the host. On Windows, `~` and `/tmp` map to the user's
    /// home and temp folders (so the default upload folder works there too).
    public func resolveDirectory(_ directory: String) async throws -> String {
        let platform = await executor.resolvedPlatform()
        guard platform.isWindows else { return directory }
        let out = try await executor.output(RemoteScript("", windows: WindowsFileScripts.pathHelper + "Slash (WinPath $A[0])\n"),
                                            arguments: [directory], purpose: "files")
        return out.split(separator: "\n").first.map(String.init) ?? directory
    }

    /// Packs items of one folder into a .tar.gz next to them; returns the archive's path.
    public func compress(_ names: [String], in directory: String, archiveName: String) async throws -> String {
        let unique = try await uniqueNames(in: directory, for: [archiveName]).first ?? archiveName
        _ = try await executor.output(RemoteScript(#"d="$1"; a="$2"; shift 2; cd -- "$d" && tar -czf "$a" -- "$@""#,
                                                   windows: WindowsFileScripts.compress),
                                      arguments: [directory, unique] + names, timeout: 1800, purpose: "files")
        return (directory == "/" ? "" : directory) + "/" + unique
    }

    public func makeDirectory(_ path: String) async throws {
        _ = try await executor.output(RemoteScript(#"mkdir -p -- "$1""#, windows: WindowsFileScripts.makeDirectory), arguments: [path], purpose: "files")
    }

    public func rename(_ path: String, to newPath: String) async throws {
        _ = try await executor.output(RemoteScript(#"mv -- "$1" "$2""#, windows: WindowsFileScripts.rename), arguments: [path, newPath], purpose: "files")
    }

    public func delete(_ path: String) async throws {
        guard path != "/" && !path.isEmpty else { throw RemoteError("Refusing to delete the root directory.") }
        _ = try await executor.output(RemoteScript(#"rm -rf -- "$1""#, windows: WindowsFileScripts.delete), arguments: [path], timeout: 120, purpose: "files")
    }

    /// Extra details for the inspector: `file` type description and directory size.
    public func details(_ file: RemoteFile) async -> (description: String?, totalSize: Int64?) {
        let script = #"""
export LC_ALL=C
file -b -- "$1" 2>/dev/null | head -n1
if [ -d "$1" ]; then du -sk -- "$1" 2>/dev/null | cut -f1; fi
"""#
        guard let text = try? await executor.output(RemoteScript(script, windows: WindowsFileScripts.details), arguments: [file.path],
                                                    timeout: 30, purpose: "files") else {
            return (nil, nil)
        }
        let lines = text.split(separator: "\n").map(String.init)
        let description = lines.first
        let size = lines.count > 1 ? Int64(lines[1]).map { $0 * 1024 } : nil
        return (description, size)
    }

    /// Reads a small text file (for previews). Limited to `maxBytes`.
    public func readHead(_ path: String, maxBytes: Int = 256 * 1024) async throws -> String {
        try await executor.output(RemoteScript(#"head -c "$2" -- "$1""#, windows: WindowsFileScripts.readHead), arguments: [path, String(maxBytes)], purpose: "files")
    }
}
