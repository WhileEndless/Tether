import Foundation
import TetherCore

/// A password / passphrase / confirmation prompt raised by ssh through SSH_ASKPASS.
public struct AskPassRequest: Sendable {
    public var token: String
    public var targetKey: String
    public var purpose: String
    public var prompt: String
    /// How many prompts this token has produced so far (1-based). Used to detect wrong saved passwords.
    public var sequence: Int

    public var isSecret: Bool {
        let p = prompt.lowercased()
        return p.contains("password") || p.contains("passphrase") || p.contains("pin") || p.contains("verification code")
    }

    public var isPasswordPrompt: Bool { prompt.lowercased().contains("password") }

    public var isConfirmation: Bool {
        let p = prompt.lowercased()
        return p.contains("(yes/no") || p.contains("continue connecting")
    }
}

/// Handles askpass prompts. Return nil to cancel.
public typealias AskPassHandler = @Sendable (AskPassRequest) async -> String?

/// Bridges ssh's SSH_ASKPASS mechanism to the app.
///
/// ssh runs the small `tether-askpass` helper, which connects to a Unix socket owned by the app and
/// forwards the prompt along with a per-process token. The app answers from the keychain or by
/// asking the user. Secrets never appear in command lines or files.
public final class AskPassBridge: @unchecked Sendable {
    public static let shared = AskPassBridge()

    private struct Context { var targetKey: String; var purpose: String; var count: Int }

    private let lock = NSLock()
    private var contexts: [String: Context] = [:]
    private var listenFD: Int32 = -1
    private var handler: AskPassHandler?

    public var helperPath: String? {
        let dir = Bundle.main.executableURL?.deletingLastPathComponent()
        let candidates = [dir?.appendingPathComponent("tether-askpass").path,
                          Bundle.main.path(forAuxiliaryExecutable: "tether-askpass")]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public var isAvailable: Bool { listenFD >= 0 && helperPath != nil }

    /// Starts listening. Call once at app launch.
    public func start(handler: @escaping AskPassHandler) {
        lock.lock(); self.handler = handler; lock.unlock()
        guard listenFD < 0 else { return }
        let path = AppPaths.askPassSocket.path
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else { close(fd); return }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { strncpy($0, path, maxLen - 1) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); return }
        chmod(path, 0o600)
        listenFD = fd
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    /// Registers a new token for one ssh process and returns the environment to give it.
    /// - Parameter mode: "force" for non-interactive processes, "prefer" to answer even with a TTY.
    public func environment(targetKey: String, purpose: String, mode: String = "force") -> [String: String] {
        guard isAvailable, let helperPath else { return [:] }
        let token = UUID().uuidString
        lock.lock(); contexts[token] = Context(targetKey: targetKey, purpose: purpose, count: 0); lock.unlock()
        return [
            "SSH_ASKPASS": helperPath,
            "SSH_ASKPASS_REQUIRE": mode,
            "DISPLAY": ProcessInfo.processInfo.environment["DISPLAY"] ?? "tether:0",
            "TETHER_ASKPASS_SOCKET": AppPaths.askPassSocket.path,
            "TETHER_ASKPASS_TOKEN": token,
        ]
    }

    /// Forgets a token once its process has finished.
    public func revoke(environment env: [String: String]) {
        guard let token = env["TETHER_ASKPASS_TOKEN"] else { return }
        lock.lock(); contexts[token] = nil; lock.unlock()
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { if errno == EINTR { continue }; return }
            // Only accept peers running as the same user.
            var uid: uid_t = 0, gid: gid_t = 0
            if getpeereid(client, &uid, &gid) != 0 || uid != getuid() { close(client); continue }
            Thread.detachNewThread { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while !data.contains(0x0a) && data.count < 65536 {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data.prefix(while: { $0 != 0x0a })) as? [String: String],
              let token = obj["token"], let prompt = obj["prompt"] else { return }

        lock.lock()
        guard var ctx = contexts[token] else { lock.unlock(); reply(fd, nil); return }
        ctx.count += 1
        contexts[token] = ctx
        let handler = self.handler
        lock.unlock()

        let request = AskPassRequest(token: token, targetKey: ctx.targetKey, purpose: ctx.purpose,
                                     prompt: prompt, sequence: ctx.count)
        let semaphore = DispatchSemaphore(value: 0)
        let box = AnswerBox()
        Task {
            box.value = await handler?(request)
            semaphore.signal()
        }
        semaphore.wait()
        reply(fd, box.value)
    }

    private final class AnswerBox: @unchecked Sendable { var value: String? }

    private func reply(_ fd: Int32, _ answer: String?) {
        let obj: [String: Any] = answer.map { ["ok": true, "answer": $0] } ?? ["ok": false]
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0a)
        data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    }
}
