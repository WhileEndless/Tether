import Foundation

/// The tmux server a test started for itself (with `TMUX_TMPDIR` set to the test's folder).
///
/// It is always ended by its socket's own path, never through `TMUX_TMPDIR`: tmux quietly uses
/// the user's default server (`/tmp/tmux-<uid>/default`) when that folder is missing or unusable,
/// and `kill-server` would then end every tmux session of the user's.
public enum PrivateTmux {
    /// Where the server started with `TMUX_TMPDIR=dir` has its socket.
    public static func socket(in dir: URL) -> String {
        dir.appendingPathComponent("tmux-\(getuid())", isDirectory: true).appendingPathComponent("default").path
    }

    /// Ends that server, and only that one: nothing at all when there is no socket there.
    public static func killServer(in dir: URL) {
        let path = socket(in: dir)
        let standard = (path as NSString).standardizingPath
        // Never the user's own default server, whatever folder was given.
        guard !standard.hasPrefix("/tmp/tmux-"), !standard.hasPrefix("/private/tmp/tmux-") else { return }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK else { return }
        guard let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux", "/usr/bin/tmux"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        var env = ProcessInfo.processInfo.environment
        env["TMUX"] = nil
        env["TMUX_TMPDIR"] = dir.path
        BoundedProcess.run(tmux, ["-S", path, "kill-server"], environment: env, timeout: 10)
    }
}
