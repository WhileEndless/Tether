import Foundation

/// One Tether per data folder: two copies at once would remove each other's open recordings,
/// take over each other's password prompts and overwrite each other's files. The lock is an
/// `flock` on a file in the data folder; the system releases it when the process ends, however it
/// ends, so it can never be left stale. Test and demo runs use their own data folder, and so their
/// own lock.
public enum InstanceLock {
    nonisolated(unsafe) private static var held: Int32 = -1

    /// Takes the lock for `directory` (the data folder by default). False when another process
    /// holds it. The lock is kept until the process ends.
    @discardableResult
    public static func acquire(in directory: URL = AppPaths.supportDirectory) -> Bool {
        let path = directory.appendingPathComponent(".lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return true }          // cannot tell: never keep Tether from starting
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        held = fd
        return true
    }

    /// Whether some process holds the lock for `directory` (without taking it).
    public static func isHeld(in directory: URL) -> Bool {
        let fd = open(directory.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(fd, LOCK_UN)
        return false
    }
}
