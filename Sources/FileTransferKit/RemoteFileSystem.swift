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
        let text = try await executor.output(script: Self.listScript, arguments: [path ?? ""], timeout: 30, purpose: "files")
        return Self.parseListing(text)
    }

    public static func parseListing(_ text: String) -> (directory: String, files: [RemoteFile]) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return ("/", []) }
        let dir = lines.removeFirst()
        let files: [RemoteFile] = lines.compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 7, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 8 else { return nil }
            let kind: RemoteFile.Kind
            switch f[0].lowercased() {
            case "d", "directory": kind = .directory
            case "f", "regular file", "regular empty file": kind = .file
            case "l", "symbolic link": kind = .symlink
            default: kind = .other
            }
            let name = f[7]
            let path = dir == "/" ? "/" + name : dir + "/" + name
            return RemoteFile(name: name, path: path, kind: kind, permissions: Int(f[1], radix: 8) ?? 0,
                              owner: f[2], group: f[3], size: Int64(f[4]) ?? 0,
                              modified: Date(timeIntervalSince1970: Double(f[5]) ?? 0),
                              linkTarget: f[6].isEmpty ? nil : f[6])
        }
        return (dir, files)
    }

    /// For each wanted name, a name that does not exist yet in `directory` (and is not used by an
    /// earlier name of the same batch): `report.pdf` → `report-1.pdf`, `report-2.pdf`, …
    /// Also creates the directory if needed. Never overwrites anything.
    public func uniqueNames(in directory: String, for names: [String]) async throws -> [String] {
        let script = #"""
d="$1"; shift
mkdir -p -- "$d" 2>/dev/null
[ -d "$d" ] && [ -w "$d" ] || { echo "Cannot write to $d" >&2; exit 1; }
taken=""
for n in "$@"; do
  base="$n"; ext=""
  case "$n" in
    .*.*|[!.]*.*) base="${n%.*}"; ext=".${n##*.}" ;;
  esac
  c="$n"; i=1
  while [ -e "$d/$c" ] || printf '%s
' "$taken" | grep -Fxq -- "$c"; do c="$base-$i$ext"; i=$((i+1)); done
  taken="$taken
$c"
  printf '%s
' "$c"
done
"""#
        let out = try await executor.output(script: script, arguments: [directory] + names, timeout: 30, purpose: "files")
        let result = out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard result.count == names.count else { throw RemoteError("Could not choose file names in \(directory).") }
        return result
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
        let out = try await executor.output(script: script, arguments: [directory] + paths, timeout: 600, purpose: "files")
        return out.split(separator: "\n").map(String.init)   // names skipped because they exist
    }

    /// chmod with a numeric (755) or symbolic (u+x) mode. Paths are absolute, so no `--` is needed
    /// (BSD chmod does not accept it after the mode).
    public func setPermissions(_ paths: [String], mode: String, recursive: Bool) async throws {
        _ = try await executor.output(script: #"m="$1"; r="$2"; shift 2; if [ "$r" = 1 ]; then chmod -R "$m" "$@"; else chmod "$m" "$@"; fi"#,
                                      arguments: [mode, recursive ? "1" : "0"] + paths, timeout: 120, purpose: "files")
    }

    /// Packs items of one folder into a .tar.gz next to them; returns the archive's path.
    public func compress(_ names: [String], in directory: String, archiveName: String) async throws -> String {
        let unique = try await uniqueNames(in: directory, for: [archiveName]).first ?? archiveName
        _ = try await executor.output(script: #"d="$1"; a="$2"; shift 2; cd -- "$d" && tar -czf "$a" -- "$@""#,
                                      arguments: [directory, unique] + names, timeout: 1800, purpose: "files")
        return (directory == "/" ? "" : directory) + "/" + unique
    }

    public func makeDirectory(_ path: String) async throws {
        _ = try await executor.output(script: #"mkdir -p -- "$1""#, arguments: [path], purpose: "files")
    }

    public func rename(_ path: String, to newPath: String) async throws {
        _ = try await executor.output(script: #"mv -- "$1" "$2""#, arguments: [path, newPath], purpose: "files")
    }

    public func delete(_ path: String) async throws {
        guard path != "/" && !path.isEmpty else { throw RemoteError("Refusing to delete the root directory.") }
        _ = try await executor.output(script: #"rm -rf -- "$1""#, arguments: [path], timeout: 120, purpose: "files")
    }

    /// Extra details for the inspector: `file` type description and directory size.
    public func details(_ file: RemoteFile) async -> (description: String?, totalSize: Int64?) {
        let script = #"""
export LC_ALL=C
file -b -- "$1" 2>/dev/null | head -n1
if [ -d "$1" ]; then du -sk -- "$1" 2>/dev/null | cut -f1; fi
"""#
        guard let text = try? await executor.output(script: script, arguments: [file.path], timeout: 30, purpose: "files") else {
            return (nil, nil)
        }
        let lines = text.split(separator: "\n").map(String.init)
        let description = lines.first
        let size = lines.count > 1 ? Int64(lines[1]).map { $0 * 1024 } : nil
        return (description, size)
    }

    /// Reads a small text file (for previews). Limited to `maxBytes`.
    public func readHead(_ path: String, maxBytes: Int = 256 * 1024) async throws -> String {
        try await executor.output(script: #"head -c "$2" -- "$1""#, arguments: [path, String(maxBytes)], purpose: "files")
    }
}
