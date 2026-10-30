import Foundation
import Testing
import TetherCore
import TestSupport
import SSHTransport
@testable import FileTransferKit

/// Transfers always end: cancelled ones stop their processes (also ones that ignore SIGTERM),
/// silent ones fail as stalled, quitting removes what they left — and the parallel limit frees
/// its place in every case. scp and ssh are small local shims, so no server is needed.
@MainActor
@Suite(.serialized) final class TransferStopTests {
    let root: URL
    let target = ConnectionTarget.adhoc(user: "user", host: "example.invalid", port: nil, jump: nil)

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tether-stop-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        // Whatever a failed test left running from this folder's shims is stopped.
        _ = BoundedProcess.run("/usr/bin/pkill", ["-KILL", "-f", root.path], timeout: 5)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    private func shim(_ name: String, _ body: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Runs the remote command (the last argument) with the local shell.
    private func plainSSH() throws -> URL {
        try shim("ssh", #"for a; do last=$a; done; exec /bin/sh -c "$last""#)
    }

    private func manager(ssh: URL? = nil, scp: URL? = nil, parallel: Int = 3, compression: TransferCompression = .off,
                         timeouts: TransferTimeouts) throws -> TransferManager {
        var options = SSHOptions()
        options.sshBinary = try (ssh ?? plainSSH()).path
        if let scp { options.scpBinary = scp.path }
        options.useControlMaster = false
        let m = TransferManager(options: { options }, policy: {
            TransferPolicy(parallel: parallel, archiveMode: .always, archiveThreshold: 2, compression: compression)
        })
        m.timeouts = timeouts
        return m
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func running(_ pattern: String) -> Bool {
        BoundedProcess.run("/usr/bin/pgrep", ["-f", pattern], timeout: 5).status == 0
    }

    private func contents(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func write(_ name: String, bytes: Int, in dir: URL) throws {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: bytes).write(to: url)
    }

    // MARK: scp

    /// scp that writes part of the file and then ignores SIGTERM: cancel still ends it (killed
    /// after the grace period), the partial file goes, and the queued transfer behind it runs.
    @Test func cancelledScpEndsEvenIgnoringTermAndFreesItsPlace() async throws {
        let scp = try shim("stubborn-scp", #"""
        for a; do last=$a; done
        case "$last" in *quick*) echo done > "$last"; exit 0 ;; esac
        echo partial > "$last"
        trap '' TERM
        while :; do sleep 0.1; done
        """#)
        let m = try manager(scp: scp, parallel: 1, timeouts: TransferTimeouts(stall: 60, firstData: 60, stopGrace: 0.5))
        let down = root.appendingPathComponent("down")
        try FileManager.default.createDirectory(at: down, withIntermediateDirectories: true)
        var ended: [TransferItem] = []
        let slow = m.download("/srv/big.iso", to: down.appendingPathComponent("big.iso"), target: target) { ended.append($0) }
        let quick = m.download("/srv/quick.txt", to: down.appendingPathComponent("quick.txt"), target: target) { ended.append($0) }
        #expect(await waitUntil(20) { LocalFiles.exists(down.appendingPathComponent("big.iso").path) })
        #expect(quick.state == .queued, "one at a time")
        m.cancel(slow)
        #expect(slow.isStopping)
        // Generous: the main queue (where the end is reported) is shared with the other suites.
        #expect(await waitUntil(30) { ended.count == 2 }, "\(slow.state) \(quick.state)")
        #expect(slow.state == .cancelled)
        #expect(quick.state == .completed, "the freed place went to the next one")
        #expect(!slow.isStopping)
        #expect(contents(down) == ["quick.txt"], "the partial file it made is removed")
        #expect(!running(scp.path))
    }

    /// scp that never prints progress: fails as stalled (with a clear message), killed.
    @Test func silentScpFailsAsStalled() async throws {
        let scp = try shim("silent-scp", "while :; do sleep 0.1; done")
        let m = try manager(scp: scp, timeouts: TransferTimeouts(stall: 0.4, firstData: 0.4, stopGrace: 0.5))
        let item = m.download("/srv/x.bin", to: root.appendingPathComponent("x.bin"), target: target)
        #expect(await waitUntil(6) { item.isFinished })
        guard case .failed(let message) = item.state else { Issue.record("\(item.state)"); return }
        #expect(message.contains("stalled"))
        #expect(message.contains("Retry"))
        #expect(!running(scp.path))
    }

    /// Quitting stops a running copy at once (killing what ignores SIGTERM) and removes the partial
    /// download it made; nothing was there before is touched; queued ones are cancelled.
    @Test func quittingStopsCopiesAndRemovesTheirPartialFiles() async throws {
        let scp = try shim("quit-scp", #"""
        for a; do last=$a; done
        echo partial > "$last"
        trap '' TERM
        while :; do sleep 0.1; done
        """#)
        let m = try manager(scp: scp, parallel: 1, timeouts: TransferTimeouts())
        let down = root.appendingPathComponent("quit")
        try write("keep.txt", bytes: 3, in: down)
        let item = m.download("/srv/new.log", to: down.appendingPathComponent("new.log"), target: target)
        let queued = m.download("/srv/later.log", to: down.appendingPathComponent("later.log"), target: target)
        #expect(await waitUntil(20) { LocalFiles.exists(down.appendingPathComponent("new.log").path) })
        m.stopAllForQuit(grace: 0.3)
        #expect(item.state == .cancelled)
        #expect(queued.state == .cancelled)
        #expect(contents(down) == ["keep.txt"])
        #expect(await waitUntil(3) { !self.running(scp.path) })
        // Nothing new starts while quitting.
        let after = m.download("/srv/more.log", to: down.appendingPathComponent("more.log"), target: target)
        #expect(after.state == .cancelled)
    }

    // MARK: Packed streams

    /// A packed upload cancelled mid-stream: every process ends, and the server's staging folder is
    /// gone (the unpacking script sees the stream end; Tether also removes it).
    @Test func cancelledPackedUploadLeavesNoStagingOnServer() async throws {
        // An ssh that reads its input slowly (about 300 KB/s), so the stream is still flowing.
        let err = root.appendingPathComponent("dd.err").path
        let ssh = try shim("slow-ssh", #"""
        for a; do last=$a; done
        case "$last" in
          *"tar -xf"*)
            while :; do dd bs=16384 count=1 2>"ERR" || break; grep -q '^0+0 records in' "ERR" && break; sleep 0.05; done | /bin/sh -c "$last" ;;
          *) exec /bin/sh -c "$last" ;;
        esac
        """#.replacingOccurrences(of: "ERR", with: err))
        let src = root.appendingPathComponent("src"), dest = root.appendingPathComponent("dest")
        for i in 0..<8 { try write("f\(i).bin", bytes: 512 * 1024, in: src) }
        let files = (0..<8).map { src.appendingPathComponent("f\($0).bin") }
        let m = try manager(ssh: ssh, timeouts: TransferTimeouts(stall: 60, firstData: 60, stopGrace: 0.5))
        var ended: [TransferItem] = []
        let made = m.uploadGroup(files, names: files.map(\.lastPathComponent), to: dest.path, target: target,
                                 fileCount: 8, totalBytes: 8 * 512 * 1024, pack: true) { ended += $0 }
        let item = try #require(made.first)
        #expect(item.method == .archive)
        #expect(await waitUntil(20) { self.contents(dest).contains { $0.hasPrefix(".tether-transfer-") } }, "unpacking started")
        m.cancel(item)
        #expect(await waitUntil(20) { !ended.isEmpty })
        #expect(item.state == .cancelled)
        #expect(await waitUntil(20) { self.contents(dest).isEmpty }, "\(contents(dest))")
        #expect(await waitUntil(3) { !self.running(ssh.path) })
    }

    /// A packed download whose server never sends anything fails as stalled; the local staging
    /// folder is removed and nothing else in the folder is touched.
    @Test func silentPackedDownloadFailsAsStalledAndCleansUp() async throws {
        let ssh = try shim("mute-ssh", #"""
        for a; do last=$a; done
        case "$last" in *"tar -cf"*) while :; do sleep 0.1; done ;; esac
        exec /bin/sh -c "$last"
        """#)
        let local = root.appendingPathComponent("local")
        try write("mine.txt", bytes: 4, in: local)
        let m = try manager(ssh: ssh, timeouts: TransferTimeouts(stall: 0.4, firstData: 0.4, stopGrace: 0.5))
        let made = m.downloadGroup(["a", "b"], from: "/srv", to: local, as: ["a", "b"], target: target,
                                   fileCount: 2, totalBytes: 10, pack: true)
        let item = try #require(made.first)
        #expect(await waitUntil(6) { item.isFinished })
        guard case .failed(let message) = item.state else { Issue.record("\(item.state)"); return }
        #expect(message.contains("stalled"))
        #expect(contents(local) == ["mine.txt"])
        #expect(await waitUntil(3) { !self.running(ssh.path) })
    }

    /// Cancelled while asking the server which compressors it has: ends at once (not when the
    /// answer comes) and frees its place.
    @Test func cancelWhileAskingForCompressorsEndsAtOnce() async throws {
        let ssh = try shim("slow-probe-ssh", #"""
        for a; do last=$a; done
        case "$last" in "sh -s --"*) sleep 2 ;; esac
        exec /bin/sh -c "$last"
        """#)
        let src = root.appendingPathComponent("psrc")
        for i in 0..<3 { try write("p\(i)", bytes: 10, in: src) }
        let files = (0..<3).map { src.appendingPathComponent("p\($0)") }
        let m = try manager(ssh: ssh, compression: .auto, timeouts: TransferTimeouts())
        var ended = false
        let item = try #require(m.uploadGroup(files, names: files.map(\.lastPathComponent), to: root.appendingPathComponent("pdest").path,
                                              target: ConnectionTarget.adhoc(user: "user", host: "probe-\(UUID().uuidString.prefix(6)).invalid",
                                                                             port: nil, jump: nil),
                                              fileCount: 3, totalBytes: 30, pack: true) { _ in ended = true }.first)
        try await Task.sleep(for: .milliseconds(100))
        m.cancel(item)
        #expect(await waitUntil(0.5) { ended })
        #expect(item.state == .cancelled)
        #expect(m.activeCount == 0)
        try await Task.sleep(for: .seconds(2.5))     // the answer arrives: nothing starts
        #expect(contents(root.appendingPathComponent("pdest")).isEmpty, "nothing was sent")
    }

    /// A packed download that failed (the folder was not there yet) succeeds on Retry, in its place.
    @Test func retrySendsAFailedTransferAgain() async throws {
        let remote = root.appendingPathComponent("remote"), local = root.appendingPathComponent("back")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let m = try manager(timeouts: TransferTimeouts())
        let first = try #require(m.downloadGroup(["a.txt", "b.txt"], from: remote.path, to: local, as: ["a.txt", "b.txt"],
                                                 target: target, fileCount: 2, totalBytes: 2, pack: true).first)
        #expect(await waitUntil(20) { first.isFinished })
        #expect(first.canRetry)
        try write("a.txt", bytes: 1, in: remote)
        try write("b.txt", bytes: 1, in: remote)
        m.retry(first)
        #expect(!m.items.contains { $0.id == first.id }, "replaced in the list")
        let again = try #require(m.items.first)
        #expect(await waitUntil(20) { again.isFinished })
        #expect(again.state == .completed)
        #expect(contents(local) == ["a.txt", "b.txt"])
    }

    // MARK: Scripts and helpers

    /// A compressed stream cut off at its end (the tar part complete, the compressor's own end
    /// missing) is refused, and the staging folder goes.
    @Test func truncatedCompressedStreamIsRefused() throws {
        let src = root.appendingPathComponent("tsrc"), dest = root.appendingPathComponent("tdest")
        try write("a", bytes: 2000, in: src)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let gz = root.appendingPathComponent("s.gz").path
        let r = BoundedProcess.run("/bin/sh", ["-c", #"""
        tar -cf - -C "$2" a | gzip -c > "$3"
        n=$(( $(wc -c < "$3") - 8 ))
        head -c "$n" "$3" | /bin/sh -c "$1" sh gzip "$4" .tether-transfer-abcdef123456 a a
        """#, "sh", ArchiveJob.unpackScript, src.path, gz, dest.path], timeout: 20)
        #expect(r.status != 0)
        #expect(contents(dest).isEmpty, "\(contents(dest))")
    }

    @Test func connectionLossIsNamed() {
        for text in ["client_loop: send disconnect: Broken pipe", "Connection to example.com closed by remote host.",
                     "lost connection", "mux_client_request_session: read from master failed: Connection reset by peer"] {
            #expect(TransferFailure.isLostConnection(text), "\(text)")
            #expect(TransferFailure.message(text, host: "example.com", fallback: "").contains("Retry"))
        }
        #expect(!TransferFailure.isLostConnection("tar: a: Cannot open: Permission denied"))
        #expect(TransferFailure.message("tar: a: Cannot open: Permission denied", host: "h", fallback: "x") == "tar: a: Cannot open: Permission denied")
        #expect(ScpJob.describe(1 << 8) == "scp exited with code 1")
    }

    /// Counting shows its total as it goes and stops when cancelled.
    @Test func countingIsCancellableAndCountsLikeTar() throws {
        let dir = root.appendingPathComponent("count")
        for i in 0..<40 { try write("sub\(i % 4)/f\(i)", bytes: 100, in: dir) }
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("link").path, withDestinationPath: "/nowhere")
        let size = LocalFiles.measure([dir])
        #expect(size == TransferSize(files: 41, bytes: 4000), "links count as files, folders by their contents")
        let counter = MeasureCounter()
        counter.cancel()
        #expect(LocalFiles.measure([dir], counter: counter).files < 41)
        let live = MeasureCounter()
        _ = LocalFiles.measure([dir], counter: live)
        #expect(live.snapshot.files == 41)
    }

    @Test func leftoverStagingIsRemovedOnlyWhenSafe() throws {
        let dir = root.appendingPathComponent("left")
        let fm = FileManager.default
        for name in [".tether-transfer-0123456789ab", ".tether-transfer-ba9876543210", ".tether-transfer-notes", "photos"] {
            try fm.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let old = Date().addingTimeInterval(-7200)
        for name in [".tether-transfer-0123456789ab", ".tether-transfer-notes", "photos"] {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: dir.appendingPathComponent(name).path)
        }
        // A link named like a staging folder is never followed or removed.
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent(".tether-transfer-ffffffffffff").path,
                                  withDestinationPath: dir.appendingPathComponent("photos").path)
        let removed = LocalFiles.removeLeftoverStaging(in: dir)
        #expect(removed.map(\.lastPathComponent) == [".tether-transfer-0123456789ab"])
        #expect(contents(dir) == [".tether-transfer-ba9876543210", ".tether-transfer-ffffffffffff", ".tether-transfer-notes", "photos"])
    }

    /// The server's name check: many names at once, links to nowhere count as taken.
    @Test func remoteNameCheckHandlesManyNamesAndDanglingLinks() async throws {
        let dir = root.appendingPathComponent("names")
        try write("report.pdf", bytes: 1, in: dir)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("ghost.txt").path, withDestinationPath: "/nowhere")
        let fs = RemoteFileSystem(executor: RemoteExecutor(target: .local, options: SSHOptions()))
        let wanted = ["report.pdf", "ghost.txt", "a*b.txt", "a*b.txt"] + (0..<1500).map { "file-\($0 % 750).txt" }
        let start = Date()
        let names = try await fs.uniqueNames(in: dir.path, for: wanted)
        #expect(Date().timeIntervalSince(start) < 20)
        #expect(Array(names.prefix(4)) == ["report-1.pdf", "ghost-1.txt", "a*b.txt", "a*b-1.txt"])
        #expect(Set(names).count == names.count)
        #expect(names[4] == "file-0.txt" && names[754] == "file-0-1.txt")
    }

    @Test func remoteStagingCleanupRemovesOnlyStaging() async throws {
        let dir = root.appendingPathComponent("rclean")
        try write("keep", bytes: 1, in: dir.appendingPathComponent(".tether-transfer-abcdef123456"))
        try write("data", bytes: 1, in: dir.appendingPathComponent("project"))
        let fs = RemoteFileSystem(executor: RemoteExecutor(target: .local, options: SSHOptions()))
        await fs.removeStaging("project", in: dir.path)
        await fs.removeStaging("../rclean", in: dir.path)
        #expect(contents(dir) == [".tether-transfer-abcdef123456", "project"])
        await fs.removeStaging(".tether-transfer-abcdef123456", in: dir.path)
        #expect(contents(dir) == ["project"])
    }

    // MARK: Review: reservations, end mark, quitting, retry, deletes

    /// The same folder sent twice at once: the second never writes into the first, and cancelling
    /// one never removes the other's files.
    @Test func twoUploadsOfOneNameGetTwoNames() async throws {
        let src = root.appendingPathComponent("twice"), dest = root.appendingPathComponent("twice-dest")
        try write("proj/a.txt", bytes: 5, in: src)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let m = try manager(timeouts: TransferTimeouts())
        var ended: [TransferItem] = []
        let one = m.upload(src.appendingPathComponent("proj"), to: dest.path, target: .local) { ended.append($0) }
        let two = m.upload(src.appendingPathComponent("proj"), to: dest.path, target: .local) { ended.append($0) }
        #expect(await waitUntil(10) { ended.count == 2 })
        #expect(one.state == .completed && two.state == .completed, "\(one.state) \(two.state)")
        #expect(Set([one.uploadedPath, two.uploadedPath]).count == 2)
        #expect(contents(dest) == ["proj", "proj-1"])
        #expect(contents(dest.appendingPathComponent("proj")) == ["a.txt"], "nothing copied into the other")
    }

    @Test func twoDownloadsToOneNameGetTwoNames() async throws {
        let scp = try shim("named-scp", #"""
        n=$#; i=0; src=""; dst=""
        for a; do i=$((i+1)); [ $i -eq $((n-1)) ] && src="$a"; [ $i -eq $n ] && dst="$a"; done
        sleep 0.3
        echo "${src#*:}" > "$dst"
        """#)
        let m = try manager(scp: scp, timeouts: TransferTimeouts())
        let down = root.appendingPathComponent("same")
        try FileManager.default.createDirectory(at: down, withIntermediateDirectories: true)
        var ended: [TransferItem] = []
        m.download("/a/x.txt", to: down.appendingPathComponent("x.txt"), target: target) { ended.append($0) }
        m.download("/b/x.txt", to: down.appendingPathComponent("x.txt"), target: target) { ended.append($0) }
        #expect(await waitUntil(10) { ended.count == 2 })
        #expect(ended.allSatisfy { $0.state == .completed })
        #expect(contents(down) == ["x 2.txt", "x.txt"])
    }

    /// An upload stream cut off between two files (tar alone would accept it): nothing is moved
    /// into place, and a folder that exists is never written into.
    @Test func unpackMovesNothingWithoutTheEndMarkAndNeverWritesIntoAFolder() throws {
        let src = root.appendingPathComponent("usrc"), dest = root.appendingPathComponent("udest")
        try write("a", bytes: 100, in: src)
        try write("proj/new.txt", bytes: 3, in: src)
        try write(".tether-end-abcdef123456", bytes: 0, in: src)
        try write("proj/old.txt", bytes: 3, in: dest)
        let tarFile = root.appendingPathComponent("s.tar").path
        let script = ArchiveJob.unpackScript
        // Only the first member (header and one block): cut where tar sees no damage.
        var r = BoundedProcess.run("/bin/sh", ["-c", #"""
        tar -cf "$3" --format ustar -C "$2" a .tether-end-abcdef123456
        head -c 1024 "$3" | /bin/sh -c "$1" sh - "$4" .tether-transfer-abcdef123456 .tether-end-abcdef123456 a a
        """#, "sh", script, src.path, tarFile, dest.path], timeout: 20)
        #expect(r.status != 0)
        #expect(r.errorOutput.contains("ended early"), "\(r.errorOutput)")
        #expect(contents(dest) == ["proj"])
        // Complete, but "proj" exists: refused, and nothing lands inside it.
        r = BoundedProcess.run("/bin/sh", ["-c", #"""
        tar -cf - -C "$2" proj a .tether-end-abcdef123456 | /bin/sh -c "$1" sh - "$3" .tether-transfer-abcdef123457 .tether-end-abcdef123456 proj proj a a
        """#, "sh", script, src.path, dest.path], timeout: 20)
        #expect(r.status != 0)
        #expect(r.errorOutput.contains("proj already exists"))
        #expect(contents(dest) == ["a", "proj"])
        #expect(contents(dest.appendingPathComponent("proj")) == ["old.txt"])
    }

    /// A copy that had just finished when Tether quits (its end not handled yet) is kept.
    @Test func quittingKeepsACopyThatHadFinished() async throws {
        let scp = try shim("fast-scp", #"for a; do last=$a; done; echo complete > "$last""#)
        let m = try manager(scp: scp, timeouts: TransferTimeouts())
        let down = root.appendingPathComponent("fast")
        try FileManager.default.createDirectory(at: down, withIntermediateDirectories: true)
        let item = m.download("/srv/done.txt", to: down.appendingPathComponent("done.txt"), target: target)
        // It ends meanwhile; the main thread (blocked here, as when quitting) has not seen that yet.
        // Waited for, not a fixed time: on a busy Mac scp takes longer to start and end.
        let file = down.appendingPathComponent("done.txt").path
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: file), !running(scp.path) { break }
            usleep(100_000)
        }
        usleep(200_000)
        m.stopAllForQuit(grace: 0.3)
        #expect(item.state == .completed, "\(item.state)")
        #expect(contents(down) == ["done.txt"])
    }

    /// Retry pressed twice sends the transfer once.
    @Test func retryTwiceSendsOnce() async throws {
        let src = root.appendingPathComponent("rsrc")
        for i in 0..<3 { try write("r\(i)", bytes: 4, in: src) }
        let files = (0..<3).map { src.appendingPathComponent("r\($0)") }
        let blocker = root.appendingPathComponent("rblock")
        try Data().write(to: blocker)
        let m = try manager(timeouts: TransferTimeouts())
        var reports = 0
        let first = try #require(m.uploadGroup(files, names: files.map(\.lastPathComponent), to: blocker.path, target: target,
                                               fileCount: 3, totalBytes: 12, pack: true) { _ in reports += 1 }.first)
        #expect(await waitUntil(5) { first.isFinished })
        #expect(first.canRetry)
        try FileManager.default.removeItem(at: blocker)
        m.retry(first)
        m.retry(first)
        #expect(!first.canRetry)
        #expect(await waitUntil(10) { m.items.count == 1 && m.items[0].id != first.id && m.items[0].isFinished })
        try await Task.sleep(for: .milliseconds(300))     // a second send would have shown up by now
        #expect(m.items.count == 1)
        #expect(m.items.first?.state == .completed)
        #expect(contents(blocker) == ["r0", "r1", "r2"])
        #expect(reports == 2, "the group hears of the retried transfer too")
    }

    /// A large folder is gone from view at once and removed in the background.
    @Test func discardIsImmediateForTheName() async throws {
        let dir = root.appendingPathComponent("discard")
        for i in 0..<200 { try write("big/f\(i)", bytes: 10, in: dir) }
        try write("keep.txt", bytes: 1, in: dir)
        LocalFiles.discard(dir.appendingPathComponent("big"))
        #expect(!contents(dir).contains("big"))
        #expect(await waitUntil(5) { self.contents(dir) == ["keep.txt"] })
    }
}
