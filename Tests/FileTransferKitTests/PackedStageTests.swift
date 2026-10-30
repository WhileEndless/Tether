import Foundation
import Testing
import TetherCore
import TestSupport
import SSHTransport
@testable import FileTransferKit

/// Packed transfers stage by stage: what they say they do, how they choose to compress, and that
/// a cancel, a dropped connection or quitting at any stage — and success — leaves nothing on
/// either end that the transfer made, except complete files already moved into place.
/// The "server" is this Mac through a fake ssh whose tools can be slowed down (wrappers on PATH).
@MainActor
@Suite(.serialized) final class PackedStageTests {
    let root: URL
    let bin: URL
    let ssh: URL
    let target: ConnectionTarget

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tether-stage-\(UUID().uuidString.prefix(8))")
        bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // Its own host name each run: what a host has and how busy it is is kept per host.
        target = .adhoc(user: "user", host: "stage-\(UUID().uuidString.prefix(6)).invalid", port: nil, jump: nil)
        ssh = root.appendingPathComponent("ssh")
        try write(ssh, #"""
        #!/bin/sh
        for a; do last=$a; done
        D="ROOT"
        if [ "$last" = "sh -s --" ] && [ -f "$D/probe.txt" ]; then cat "$D/probe.txt"; exit 0; fi
        export PATH="$D/bin:$PATH"
        [ -f "$D/before.sh" ] && . "$D/before.sh"
        # Not exec: the remote command outlives a stopped ssh, as on a real server.
        /bin/sh -c "$last"
        exit $?
        """#.replacingOccurrences(of: "ROOT", with: root.path))
    }

    deinit {
        _ = BoundedProcess.run("/usr/bin/pkill", ["-KILL", "-f", root.path], timeout: 5)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    private func write(_ url: URL, _ text: String, executable: Bool = true) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    /// A tool on the "server" that waits before (or after) doing its work.
    private func slow(_ tool: String, _ body: String) throws {
        try write(bin.appendingPathComponent(tool), "#!/bin/sh\n" + body + "\n")
    }

    /// What the "server" answers to the host question.
    private func probe(_ text: String) throws {
        try write(root.appendingPathComponent("probe.txt"), text + "\n", executable: false)
    }

    private func before(_ text: String) throws {
        try write(root.appendingPathComponent("before.sh"), text + "\n", executable: false)
    }

    private func manager(compression: TransferCompression = .off, adapt: Bool = false, scp: URL? = nil) -> TransferManager {
        var options = SSHOptions()
        options.sshBinary = ssh.path
        if let scp { options.scpBinary = scp.path }
        options.useControlMaster = false
        let m = TransferManager(options: { options }, policy: {
            TransferPolicy(parallel: 3, archiveMode: .always, archiveThreshold: 2, compression: compression, adaptToSlowHosts: adapt)
        })
        m.timeouts = TransferTimeouts(stall: 60, firstData: 60, stopGrace: 0.5)
        return m
    }

    private func files(_ count: Int, bytes: Int = 64 * 1024, in dir: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try (0..<count).map { i in
            let url = dir.appendingPathComponent("f\(i).bin")
            try Data(repeating: UInt8(0x41 + i % 26), count: bytes).write(to: url)
            return url
        }
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func contents(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func noStaging(_ dir: URL) -> Bool {
        !contents(dir).contains { $0.hasPrefix(".tether-") }
    }

    /// The end-mark folder an upload keeps on this Mac while it runs.
    private func endMarkGone(_ item: TransferItem) -> Bool {
        !LocalFiles.exists(FileManager.default.temporaryDirectory.appendingPathComponent("tether-end-\(item.id.uuidString)").path)
    }

    private func upload(_ m: TransferManager, _ files: [URL], to dest: URL, bytes: Int64? = nil,
                        ended: @escaping ([TransferItem]) -> Void = { _ in }) throws -> TransferItem {
        try #require(m.uploadGroup(files, names: files.map(\.lastPathComponent), to: dest.path, target: target,
                                   fileCount: files.count, totalBytes: bytes, pack: true, completion: ended).first)
    }

    // MARK: Success

    @Test func successLeavesNothingExtraOnEitherEnd() async throws {
        guard ArchiveJob.localPath("gzip") != nil else { return }
        try probe("z gzip\ntar yes\ncpu 8 0.5")
        let m = manager(compression: .gzip)
        let src = root.appendingPathComponent("src"), dest = root.appendingPathComponent("dest")
        let up = try upload(m, try files(6, in: src), to: dest)
        var stages: [TransferStage] = []
        #expect(await waitUntil(30) {
            if let s = up.stage, stages.last != s { stages.append(s) }
            return up.isFinished
        })
        #expect(up.state == .completed, "\(up.state)")
        #expect(up.compression == .gzip)
        #expect(!stages.contains(.waitingForAnswer))
        #expect(contents(dest) == (0..<6).map { "f\($0).bin" }.sorted())
        #expect(endMarkGone(up))
        // And back down: nothing extra here either.
        let back = root.appendingPathComponent("back")
        try FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
        let names = (0..<6).map { "f\($0).bin" }
        let down = try #require(m.downloadGroup(names, from: dest.path, to: back, as: names, target: target,
                                                fileCount: 6, totalBytes: nil, pack: true).first)
        #expect(await waitUntil(30) { down.isFinished })
        #expect(down.state == .completed)
        #expect(await waitUntil(3) { self.contents(back) == names.sorted() })
        #expect(contents(dest) == names.sorted(), "the server's side is left as it was")
    }

    // MARK: Cancel at each stage (upload)

    @Test func cancelWhileCheckingNamesLeavesNothing() async throws {
        try probe("tar yes\ncpu 8 0.5")
        try before(#"case "$last" in "sh -s -- "*) sleep 2 ;; esac"#)
        let m = manager()
        let dest = root.appendingPathComponent("names-dest")
        let up = try upload(m, try files(3, in: root.appendingPathComponent("nsrc")), to: dest)
        #expect(await waitUntil(5) { up.stage == .checkingNames })
        m.cancel(up)
        #expect(up.state == .cancelled)
        try await Task.sleep(for: .seconds(2.5))
        #expect(!LocalFiles.exists(dest.path), "the destination folder is not even made")
        #expect(endMarkGone(up))
    }

    @Test func cancelWhileUnpackingOnTheServerLeavesNothing() async throws {
        try probe("tar yes\ncpu 8 0.5")
        // The server's tar takes a while after reading everything.
        try slow("tar", #"/usr/bin/tar "$@"; s=$?; case "$1" in -x*) sleep 2 ;; esac; exit $s"#)
        let m = manager()
        let dest = root.appendingPathComponent("unpack-dest")
        let up = try upload(m, try files(4, in: root.appendingPathComponent("usrc")), to: dest)
        #expect(await waitUntil(5) { up.stage == .finishing }, "\(String(describing: up.stage))")
        m.cancel(up)
        #expect(await waitUntil(5) { up.isFinished })
        #expect(up.state == .cancelled)
        #expect(await waitUntil(6) { !LocalFiles.exists(dest.path) }, "\(contents(dest))")
        #expect(endMarkGone(up))
    }

    @Test func cancelWhileMovingIntoPlaceKeepsOnlyCompleteItems() async throws {
        try probe("tar yes\ncpu 8 0.5")
        try slow("ln", #"sleep 0.7; exec /bin/ln "$@""#)
        let m = manager()
        let dest = root.appendingPathComponent("move-dest")
        let src = root.appendingPathComponent("msrc")
        let up = try upload(m, try files(5, in: src), to: dest)
        #expect(await waitUntil(8) { up.stage == .movingIntoPlace }, "\(String(describing: up.stage))")
        m.cancel(up)
        #expect(await waitUntil(5) { up.isFinished })
        #expect(await waitUntil(8) { self.noStaging(dest) || !LocalFiles.exists(dest.path) })
        try await Task.sleep(for: .seconds(1.5))      // what the server still finishes
        for name in contents(dest) {
            #expect(name.hasPrefix("f"), "\(name)")
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.appendingPathComponent(name).path)[.size] as? Int) ?? -1
            #expect(size == 64 * 1024, "\(name) is complete")
        }
        #expect(noStaging(dest))
        if up.state == .cancelled { #expect(up.note?.contains("moving into place") == true) }
        #expect(endMarkGone(up))
    }

    @Test func cancelWhileRemovingTemporaryFilesKeepsTheCompleteResult() async throws {
        try probe("tar yes\ncpu 8 0.5")
        try slow("rm", #"case "$*" in *-rf*.tether-transfer-*) sleep 1.5 ;; esac; exec /bin/rm "$@""#)
        let m = manager()
        let dest = root.appendingPathComponent("rm-dest")
        let up = try upload(m, try files(3, in: root.appendingPathComponent("rsrc")), to: dest)
        #expect(await waitUntil(8) { up.stage == .removingTemporary }, "\(String(describing: up.stage))")
        m.cancel(up)
        #expect(await waitUntil(5) { up.isFinished })
        #expect(await waitUntil(8) { self.noStaging(dest) })
        #expect(contents(dest) == ["f0.bin", "f1.bin", "f2.bin"])
    }

    // MARK: Downloads

    @Test func cancelWhilePackingOnTheServerLeavesNothingHere() async throws {
        try probe("tar yes\ncpu 8 0.5")
        try before(#"case "$last" in *"tar -cf"*) sleep 3 ;; esac"#)
        let remote = root.appendingPathComponent("remote")
        _ = try files(3, in: remote)
        let local = root.appendingPathComponent("here")
        try write(local.appendingPathComponent("mine.txt"), "mine", executable: false)
        let m = manager()
        let down = try #require(m.downloadGroup(["f0.bin", "f1.bin", "f2.bin"], from: remote.path, to: local, as: ["f0.bin", "f1.bin", "f2.bin"],
                                                target: target, fileCount: 3, totalBytes: nil, pack: true).first)
        #expect(await waitUntil(5) { down.stage == .streaming })
        #expect(down.stageText?.contains("on \(target.displayName)") == true, "packing happens on the server")
        m.cancel(down)
        #expect(await waitUntil(5) { down.isFinished })
        #expect(down.state == .cancelled)
        #expect(await waitUntil(3) { self.contents(local) == ["mine.txt"] })
    }

    // MARK: Connection drops and quitting

    @Test func droppedConnectionWhileSendingFailsAndCleansBothEnds() async throws {
        try probe("tar yes\ncpu 8 0.5")
        try before(#"""
        case "$last" in *"tar -xf"*)
          head -c 100000 | /bin/sh -c "$last"
          echo "Connection to example.invalid closed by remote host." >&2
          exit 255 ;;
        esac
        """#)
        let m = manager()
        let dest = root.appendingPathComponent("drop-dest")
        let up = try upload(m, try files(8, bytes: 256 * 1024, in: root.appendingPathComponent("dsrc")), to: dest)
        #expect(await waitUntil(30) { up.isFinished })
        guard case .failed(let message) = up.state else { Issue.record("\(up.state)"); return }
        #expect(message.contains("connection"), "\(message)")
        #expect(await waitUntil(5) { !LocalFiles.exists(dest.path) }, "\(contents(dest))")
        #expect(up.canRetry)
        #expect(endMarkGone(up))
    }

    @Test func droppedConnectionWhileDownloadingFailsAndCleansHere() async throws {
        try probe("tar yes\ncpu 8 0.5")
        try before(#"""
        case "$last" in *"tar -cf"*)
          /bin/sh -c "$last" | head -c 50000
          echo "client_loop: send disconnect: Broken pipe" >&2
          exit 255 ;;
        esac
        """#)
        let remote = root.appendingPathComponent("dremote")
        _ = try files(6, bytes: 128 * 1024, in: remote)
        let local = root.appendingPathComponent("dlocal")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let names = (0..<6).map { "f\($0).bin" }
        let m = manager()
        let down = try #require(m.downloadGroup(names, from: remote.path, to: local, as: names, target: target,
                                                fileCount: 6, totalBytes: nil, pack: true).first)
        #expect(await waitUntil(30) { down.isFinished })
        guard case .failed(let message) = down.state else { Issue.record("\(down.state)"); return }
        #expect(message.contains("connection"))
        #expect(await waitUntil(3) { self.contents(local).isEmpty }, "\(contents(local))")
    }

    @Test func quittingWhileSendingCleansBothEnds() async throws {
        try probe("tar yes\ncpu 8 0.5")
        let err = root.appendingPathComponent("dd.err").path
        try before(#"""
        case "$last" in *"tar -xf"*)
          while :; do dd bs=16384 count=1 2>"ERR" || break; grep -q '^0+0 records in' "ERR" && break; sleep 0.05; done | /bin/sh -c "$last"
          exit $? ;;
        esac
        """#.replacingOccurrences(of: "ERR", with: err))
        let m = manager()
        let dest = root.appendingPathComponent("quit-dest")
        let up = try upload(m, try files(8, bytes: 512 * 1024, in: root.appendingPathComponent("qsrc")), to: dest)
        #expect(await waitUntil(5) { self.contents(dest).contains { $0.hasPrefix(".tether-transfer-") } })
        m.stopAllForQuit(grace: 0.3)
        #expect(up.state == .cancelled)
        #expect(endMarkGone(up))
        #expect(await waitUntil(8) { !LocalFiles.exists(dest.path) }, "\(contents(dest))")
    }

    @Test func quittingWhileWaitingForAnAnswerEndsIt() async throws {
        try probe("z gzip\ntar yes\ncpu 1 3.0")
        let m = manager(compression: .gzip, adapt: true)
        let remote = root.appendingPathComponent("qremote")
        _ = try files(3, in: remote)
        let local = root.appendingPathComponent("qlocal")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let down = try #require(m.downloadGroup(["f0.bin", "f1.bin", "f2.bin"], from: remote.path, to: local, as: ["f0.bin", "f1.bin", "f2.bin"],
                                                target: target, fileCount: 3, totalBytes: 300 << 20, pack: true).first)
        #expect(await waitUntil(5) { down.question != nil })
        m.stopAllForQuit(grace: 0.3)
        #expect(down.state == .cancelled)
        #expect(contents(local).isEmpty)
    }

    // MARK: Choosing how to send

    /// A method chosen in Settings on a slow server, for a large transfer: asked first; the answer
    /// kept for the host is not asked again.
    @Test func slowServerIsAskedAboutOnceWhenRemembered() async throws {
        try probe("z gzip\ntar yes\ncpu 2 3.4")
        let m = manager(compression: .gzip, adapt: true)
        let remote = root.appendingPathComponent("aremote")
        _ = try files(3, in: remote)
        let names = ["f0.bin", "f1.bin", "f2.bin"]
        let first = root.appendingPathComponent("a1"), second = root.appendingPathComponent("a2")
        for d in [first, second] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let one = try #require(m.downloadGroup(names, from: remote.path, to: first, as: names, target: target,
                                               fileCount: 3, totalBytes: 300 << 20, pack: true).first)
        #expect(await waitUntil(5) { one.question != nil })
        #expect(one.question?.text.contains("2 cores, load 3.4") == true)
        #expect(one.stageText == one.question?.text)
        m.answer(one, compress: false, remember: true)
        #expect(await waitUntil(30) { one.isFinished })
        #expect(one.state == .completed)
        #expect(one.compression == nil)
        let two = try #require(m.downloadGroup(names, from: remote.path, to: second, as: names, target: target,
                                               fileCount: 3, totalBytes: 300 << 20, pack: true).first)
        var asked = false
        #expect(await waitUntil(30) { asked = asked || two.question != nil; return two.isFinished })
        #expect(!asked)
        #expect(two.state == .completed && two.compression == nil)
    }

    /// Automatic compression on a slow server: something light or nothing, said in a note.
    @Test func automaticCompressionGoesLightOnASlowServer() async throws {
        guard ArchiveJob.localPath("gzip") != nil else { return }
        try probe("z gzip\ntar yes\ncpu 1 0.2")
        let m = manager(compression: .auto, adapt: true)
        let remote = root.appendingPathComponent("lremote")
        _ = try files(3, in: remote)
        let local = root.appendingPathComponent("llocal")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let names = ["f0.bin", "f1.bin", "f2.bin"]
        let down = try #require(m.downloadGroup(names, from: remote.path, to: local, as: names, target: target,
                                                fileCount: 3, totalBytes: nil, pack: true).first)
        #expect(await waitUntil(30) { down.isFinished })
        #expect(down.state == .completed)
        #expect(down.compression == nil || down.compression == .lz4)
        #expect(down.note?.contains("slow to compress") == true)
    }

    /// No tar on the server: no packed way exists, so the files go one by one, saying why.
    @Test func noTarOnTheServerSendsFileByFile() async throws {
        try probe("z gzip\ncpu 8 0.1")
        let scp = root.appendingPathComponent("scp")
        try write(scp, #"""
        #!/bin/sh
        n=$#; i=0; src=""; dst=""
        for a; do i=$((i+1)); [ $i -eq $((n-1)) ] && src="$a"; [ $i -eq $n ] && dst="$a"; done
        exec /bin/cp -R "${src#*:}" "${dst#*:}"
        """#)
        let m = manager(scp: scp)
        let remote = root.appendingPathComponent("tremote")
        _ = try files(4, in: remote)
        let local = root.appendingPathComponent("tlocal")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let names = (0..<4).map { "f\($0).bin" }
        var made: [TransferItem] = []
        m.downloadGroup(names, from: remote.path, to: local, as: names, target: target, fileCount: 4, totalBytes: nil, pack: true) { made = $0 }
        #expect(await waitUntil(30) { made.count == 4 })
        #expect(made.allSatisfy { $0.method == .scp && $0.state == .completed })
        #expect(made.first?.note?.contains("no tar") == true)
        #expect(contents(local) == names)
    }

    // MARK: Pure parts

    @MainActor @Test func stageTextSaysWhereItRuns() {
        let host = ConnectionTarget.adhoc(user: "user", host: "example.com", port: nil, jump: nil)
        let up = TransferItem(direction: .upload, method: .archive, target: host, localURL: URL(fileURLWithPath: "/tmp"), remotePath: "/srv")
        up.state = .running
        up.compression = .zstd
        up.stage = .streaming
        #expect(up.stageText == "Packing and compressing (zstd) on this Mac, sending, unpacking on \(host.displayName)")
        up.stage = .movingIntoPlace
        #expect(up.stageText == "Moving into place on \(host.displayName)…")
        let down = TransferItem(direction: .download, method: .archive, target: host, localURL: URL(fileURLWithPath: "/tmp"), remotePath: "/srv")
        down.state = .running
        down.stage = .streaming
        #expect(down.stageText == "Packing on \(host.displayName), sending, unpacking on this Mac")
        down.stage = .finishing
        #expect(down.stageText == "Unpacking on this Mac…")
        down.state = .completed
        #expect(down.stageText == nil)
    }

    @Test func probeAnswerIsRead() {
        let p = HostProbe.parse("z zstd\nz nonsense\nz gzip\ntar yes\ncpu 4 1.25\n")
        #expect(p.programs == ["zstd", "gzip"])
        #expect(p.hasTar)
        #expect(p.cpu == HostCPU(cores: 4, load: 1.25))
        #expect(HostProbe.parse("cpu ? ?").cpu == HostCPU(cores: nil, load: nil))
        #expect(!HostProbe.parse("cpu 8 0.3").hasTar)
    }

    @Test func probeScriptRunsHere() {
        let r = BoundedProcess.run("/bin/sh", ["-c", HostProbe.script], timeout: 20)
        let p = HostProbe.parse(r.output)
        #expect(p.hasTar)
        #expect(p.programs.contains("gzip"))
        #expect((p.cpu.cores ?? 0) >= 1)
        #expect(p.cpu.load != nil)
    }

    @Test func compressionAdviceFollowsTheCompressingEnd() {
        let weak = HostCPU(cores: 2, load: 3.4), fast = HostCPU(cores: 8, load: 1)
        let both: Set<String> = ["zstd", "lz4", "gzip", "xz"]
        func decide(_ chosen: TransferCompression, _ resolved: TransferCompression?, _ cpu: HostCPU, bytes: Int64?, both: Set<String> = both) -> CompressionAdvice {
            CompressionAdvice.decide(chosen: chosen, resolved: resolved, both: both, side: "example.com", cpu: cpu, bytes: bytes, adapt: true)
        }
        #expect(decide(.auto, .zstd, fast, bytes: 1 << 30) == .use(.zstd))
        #expect(decide(.auto, .zstd, weak, bytes: 1 << 30) == .use(.lz4))
        #expect(decide(.auto, .gzip, weak, bytes: nil, both: ["gzip"]) == .use(nil))
        #expect(decide(.xz, .xz, weak, bytes: 1 << 20) == .use(.xz), "small: never held up")
        #expect(decide(.xz, .xz, weak, bytes: 100 << 20) == .ask(CompressionQuestion(text: "example.com is slow to compress (2 cores, load 3.4).", method: .xz)))
        #expect(decide(.zstd, .zstd, weak, bytes: 100 << 20) == .use(.zstd), "light and not large: as chosen")
        #expect(decide(.zstd, .zstd, weak, bytes: 1 << 30) != .use(.zstd), "large: asked")
        #expect(decide(.xz, .xz, fast, bytes: 1 << 30) == .use(.xz))
        #expect(CompressionAdvice.decide(chosen: .auto, resolved: .zstd, both: both, side: "x", cpu: weak, bytes: nil, adapt: false) == .use(.zstd))
        #expect(HostCPU(cores: 16, load: 30).isWeak)
        #expect(!HostCPU(cores: nil, load: 9).isWeak)
    }
}
