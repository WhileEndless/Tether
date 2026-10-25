import Foundation
import Testing
import SSHTransport
import TetherCore
@testable import MonitorKit

/// The command running in a terminal: parsing what hosts report, finding the foreground job and
/// computing usage between looks.
@Suite struct CommandStatsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Linux: bash (pid 100, group 100) runs `make` (group 200, the terminal's foreground) which
    /// started `cc`; a background `sleep` (group 300) is not part of the command.
    let linux = """
    @@root
    100
    @@now
    1800000000
    @@linux
    100
    4096
    1799990000
    @@procs
    100 1 100 200 S 50 1 100000 1000
    200 100 200 200 S 300 1 950000 2000
    300 100 300 200 S 0 1 960000 100
    201 200 200 200 R 1200 4 990000 50000
    @@detail
    200\t1000\t4096 8192\tmake -j4 all
    300\t1000\t-\tsleep 600
    201\t1000\t0 1048576\tcc -c main.c
    @@users
    1000 user
    @@sockets
    201\ttcp   ESTAB 0 0 192.0.2.10:40000 192.0.2.20:443 users:(("cc",pid=201,fd=3))
    300\ttcp   ESTAB 0 0 192.0.2.10:40001 192.0.2.20:443 users:(("sleep",pid=300,fd=3))
    """

    @Test func linuxForegroundJob() {
        let f = ProbeParser.command(linux, anchor: .posix(pid: 100), receivedAt: now)
        #expect(f.problem == nil)
        #expect(f.shellPid == 100)
        #expect(f.processes.map(\.pid) == [200, 201])
        let make = f.processes[0]
        #expect(make.commandLine == "make -j4 all")
        #expect(make.name == "make")
        #expect(make.user == "user")
        #expect(make.cpuSeconds == 3)
        #expect(make.rssBytes == Int64(2000 * 4096))
        #expect(make.readBytes == 4096 && make.writeBytes == 8192)
        // boot 1799990000 + 9500 s; the host clock equals ours here.
        #expect(make.started == Date(timeIntervalSince1970: 1_799_999_500))
        #expect(f.processes[1].threads == 4)
        #expect(f.sockets.map(\.pid) == [201])
        #expect(f.sockets.first?.peer == "192.0.2.20:443")
        #expect(f.sockets.first?.state == "ESTAB")
    }

    /// Owners and counters in one part, command lines in another (one process each, joined by pid).
    @Test func linuxCommandLinesApart() {
        let text = linux.replacingOccurrences(of: """
        200\t1000\t4096 8192\tmake -j4 all
        300\t1000\t-\tsleep 600
        201\t1000\t0 1048576\tcc -c main.c
        """, with: """
        200\t1000\t4096 8192
        201\t1000\t0 1048576
        @@cmdline
        200\tmake -j4 all
        201\tcc -c main.c
        300\tsleep 600
        """)
        let f = ProbeParser.command(text, anchor: .posix(pid: 100), receivedAt: now)
        #expect(f.processes.map(\.commandLine) == ["make -j4 all", "cc -c main.c"])
        #expect(f.leader?.readBytes == 4096 && f.leader?.user == "user")
    }

    @Test func idleShellHasNoCommand() {
        let text = linux.replacingOccurrences(of: "100 1 100 200 S", with: "100 1 100 100 S")
        let f = ProbeParser.command(text, anchor: .posix(pid: 100), receivedAt: now)
        #expect(f.problem == nil)
        #expect(f.isIdle)
    }

    /// Dates move to this Mac's clock when the host's clock is off.
    @Test func hostClockOffset() {
        let f = ProbeParser.command(linux, anchor: .posix(pid: 100), receivedAt: now.addingTimeInterval(60))
        #expect(f.leader?.started == Date(timeIntervalSince1970: 1_799_999_560))
    }

    @Test func goneShellAndScreen() {
        #expect(ProbeParser.command("@@problem\nno-shell\n", anchor: .posix(pid: 1)).problem == .noShell)
        #expect(ProbeParser.command("", anchor: .posix(pid: 1)).problem == .noShell)
        // A screen server (100) with one window shell (150) running vim.
        let screen = """
        @@root
        100
        @@now
        1800000000
        @@procs
        100 1 100 0 Ss 1000 user 0:00.10 900 01:00:00 SCREEN -S tether-x
        150 100 150 160 Ss 1000 user 0:00.20 2000 59:00 -bash
        160 150 160 160 S+ 1000 user 0:02.50 9000 10:00 vim notes.txt
        """
        let f = ProbeParser.command(screen, anchor: .screen(session: "tether-x"), receivedAt: now)
        #expect(f.shellPid == 150)
        #expect(f.leader?.name == "vim")
        let two = screen + "\n170 100 170 170 Ss 1000 user 0:00.00 100 01:00 -bash"
        #expect(ProbeParser.command(two, anchor: .screen(session: "tether-x")).problem == .screenWindows)
    }

    /// macOS / BSD ps columns, with clock-style times and lsof sockets and nettop totals.
    @Test func bsdProcesses() {
        let text = """
        @@root
        500
        @@now
        1800000000
        @@procs
          500     1   500   600 Ss     501 user               0:00.50   3000       10:00 -zsh
          600   500   600   600 S+     501 user            1:02:03.25  40000    01:00:00 python3 train.py --epochs 3
          601   600   600   600 S+     501 user               0:01.00   1000       59:59 python3 -c pass
        @@sockets
        600\tPython    600 user    5u  IPv4 0x1      0t0  TCP 192.0.2.1:50000->192.0.2.2:443 (ESTABLISHED)
        600\tPython    600 user    6u  IPv4 0x2      0t0  UDP *:5353
        @@flows
        P\t600\tPython\t1000\t2000
        F\t600\tPython\tTCP\t192.0.2.1:50000\t192.0.2.2:443\t900\t1900
        P\t601\tpython3\t10\t20
        P\t999\tother\t5\t5
        """
        let f = ProbeParser.command(text, anchor: .posix(pid: 500), receivedAt: now)
        #expect(f.processes.map(\.pid) == [600, 601])
        #expect(f.leader?.cpuSeconds == 3723.25)
        #expect(f.leader?.rssBytes == Int64(40000 * 1024))
        #expect(f.leader?.started == now.addingTimeInterval(-3600))
        #expect(f.leader?.commandLine == "python3 train.py --epochs 3")
        #expect(f.sockets.count == 2)
        #expect(f.sockets[0].state == "ESTABLISHED" && f.sockets[0].peer == "192.0.2.2:443")
        #expect(f.sockets[1].proto == "UDP" && f.sockets[1].local == "*:5353")
        #expect(f.networkBytes[600] == ByteCounts(received: 1000, sent: 2000))
        #expect(f.networkBytes[999] == nil)
        #expect(f.measuresNetwork)
        #expect(f.socketCounters.count == 1)
        // lsof and nettop name the same connection: one row, with lsof's state and nettop's bytes.
        let c = CommandSampler.connections(f, previous: nil)
        #expect(c.count == 2)
        #expect(c.first?.state == "ESTABLISHED" && c.first?.receivedBytes == 900)
    }

    /// Windows: the newest program below PowerShell leads; console hosts are left out.
    @Test func windowsProcesses() {
        let text = """
        @@root
        4000
        @@now
        1800000000
        @@windows
        4100\t4000\t0.5\t8000000\t4\t1799999000\t0\t0\tuser\tC:\\\\Windows\\\\system32\\\\conhost.exe 0x4
        4200\t4000\t12.5\t50000000\t10\t1799999900\t100\t200\tuser\tnode server.js
        4300\t4200\t1.25\t1000000\t2\t1799999950\t0\t0\tuser\tnode worker.js
        @@tcp
        TCP\tEstablished\t192.0.2.1:3000\t192.0.2.9:50000\t4200
        """
        let f = ProbeParser.command(text, anchor: .windows(commandTag: "x"), receivedAt: now)
        #expect(f.processes.map(\.pid) == [4200, 4300])
        #expect(f.leader?.cpuSeconds == 12.5)
        #expect(f.leader?.readBytes == 100)
        #expect(f.sockets.first?.state == "Established")
        #expect(ProbeParser.command("@@root\n4000\n@@windows\n", anchor: .windows(commandTag: "x")).isIdle)
    }

    @Test func programNames() {
        #expect(CommandProcess.programName("/usr/bin/python3 -m http.server") == "python3")
        #expect(CommandProcess.programName("-bash") == "bash")
        #expect(CommandProcess.programName(#""C:\Program Files\nodejs\node.exe" app.js"#) == "node.exe")
        #expect(CommandProcess.programName(#"C:\Windows\system32\conhost.exe 0x4"#) == "conhost.exe")
    }

    /// One run for several terminals: shared lines first, then one part per terminal.
    @Test func batchedLook() {
        let text = """
        @@now
        1800000000
        @@@tab 0
        @@root
        500
        @@procs
          500     1   500   600 Ss     501 user               0:00.50   3000       10:00 -zsh
          600   500   600   600 S+     501 user               0:01.00  40000       01:00 ping -c 5 192.0.2.7
        @@sockets
        600\tping    600 user    3u  IPv4 0x1      0t0  ICMP *:*
        @@@tab 1
        @@problem
        no-shell
        """
        let frames = ProbeParser.commandBatch(text, anchors: [.posix(pid: 500), .posix(pid: 900), .posix(pid: 901)], receivedAt: now)
        #expect(frames.count == 3)
        #expect(frames[0].leader?.name == "ping")
        #expect(frames[0].leader?.started == now.addingTimeInterval(-60))   // the shared clock reached the part
        #expect(frames[0].sockets.first?.proto == "ICMP" && frames[0].sockets.first?.peer == "192.0.2.7")
        #expect(frames[1].problem == .noShell)
        #expect(frames[2].problem == .noShell)   // missing from the output
    }

    /// ping on Windows (no socket to see) and on Linux (/proc/net/icmp): the target from its arguments.
    @Test func icmpTargets() {
        let ping = CommandProcess(pid: 7, ppid: 1, commandLine: "C:\\Windows\\System32\\PING.EXE -t 192.0.2.8")
        let s = ProbeParser.icmpSockets([], processes: [ping], listed: [])
        #expect(s.first?.peer == "192.0.2.8" && s.first?.state == "from command line")
        let linux = CommandProcess(pid: 8, ppid: 1, commandLine: "ping -c 3 example.com")
        let l = ProbeParser.icmpSockets(["8\tICMP"], processes: [linux], listed: [])
        #expect(l.count == 1 && l.first?.peer == "example.com" && l.first?.state == "-")
        #expect(ProbeParser.icmpTarget("ping -c 3") == nil)
        #expect(ProbeParser.icmpTarget("ping 192.0.2.1 -i 0.2") == "192.0.2.1")
        #expect(ProbeParser.icmpTarget("ping6 -c 2 2001:db8::1") == "2001:db8::1")
        let c = ConnectionTraffic(proto: "ICMP", state: "-", local: "*", peer: "192.0.2.8", pid: 8, processName: "ping")
        #expect(!c.isListening && !c.isTCPorUDP)
    }

    @Test func watcherLines() {
        #expect(WatchEvent.parse("0 busy 4242 make -j8 all")! == (0, .busy(pid: 4242, commandLine: "make -j8 all")))
        #expect(WatchEvent.parse("3 idle")! == (3, .idle))
        #expect(WatchEvent.parse("3 idle\n")! == (3, .idle))          // as the stream hands it over
        #expect(WatchEvent.parse("0 busy 7 sleep 1\r\n")! == (0, .busy(pid: 7, commandLine: "sleep 1")))
        #expect(WatchEvent.parse("1 gone")! == (1, .gone))
        #expect(WatchEvent.parse(".") == nil)
        #expect(WatchEvent.parse("x busy 1") == nil)
    }

    @Test func netstatSockets() {
        let lines = ["42\ttcp        0      0 192.0.2.1:22            192.0.2.5:51000         ESTABLISHED 42/sshd",
                     "42\tudp        0      0 0.0.0.0:68              0.0.0.0:*                           42/dhclient"]
        let s = ProbeParser.commandSockets(lines, pids: [42])
        #expect(s.map(\.state) == ["ESTABLISHED", "-"])
        #expect(s.map(\.proto) == ["TCP", "UDP"])
    }

    @Test func clockFormats() {
        #expect(ProbeParser.clockSeconds("00:05") == 5)
        #expect(ProbeParser.clockSeconds("1:02:03") == 3723)
        #expect(ProbeParser.clockSeconds("2-00:00:01") == 172_801)
        #expect(ProbeParser.clockSeconds("123:45.67")! - 7425.67 < 0.001)
        #expect(ProbeParser.clockSeconds("x") == nil)
    }

    // MARK: Usage between looks

    @Test func usageBetweenLooks() {
        let started = now.addingTimeInterval(-100)
        var a = CommandFrame(takenAt: now)
        a.processes = [CommandProcess(pid: 1, ppid: 0, cpuSeconds: 10, rssBytes: 100, threads: 2, started: started,
                                      readBytes: 1000, writeBytes: 0)]
        a.networkBytes = [1: ByteCounts(received: 0, sent: 0)]
        var b = CommandFrame(takenAt: now.addingTimeInterval(2))
        b.processes = [CommandProcess(pid: 1, ppid: 0, cpuSeconds: 12, rssBytes: 150, threads: 3, started: started,
                                      readBytes: 3000, writeBytes: 400),
                       // Started between the looks: everything it used counts.
                       CommandProcess(pid: 2, ppid: 1, cpuSeconds: 1, rssBytes: 50, threads: 1, started: now.addingTimeInterval(1))]
        b.networkBytes = [1: ByteCounts(received: 2000, sent: 200)]
        let s = CommandSampler.sample(b, previous: a, traffic: nil)
        #expect(s.cpu == 150)       // 3 s of CPU in 2 s
        #expect(s.memory == 200)
        #expect(s.threads == 4)
        #expect(s.processes == 2)
        #expect(s.read == 1000)
        #expect(s.written == 200)
        #expect(s.received == 1000 && s.sent == 100)
        // The first look of a command has no rates yet.
        #expect(CommandSampler.sample(a, previous: nil, traffic: nil).cpu == nil)
        // A reused pid is a different process.
        var c = b
        c.processes[0].started = now.addingTimeInterval(1.5)
        c.processes[0].cpuSeconds = 0.5
        #expect(CommandSampler.sample(c, previous: a, traffic: nil).cpu == 75)
    }

    /// Linux: the kernel's TCP counters give traffic per connection without capturing anything.
    @Test func connectionCounters() {
        let lines = ["F\t201\tcurl\tTCP\t192.0.2.1:40000\t192.0.2.9:443\t1000\t100",
                     "F\t201\tcurl\tTCP\t192.0.2.1:40001\t192.0.2.9:443\t-\t-",
                     "bad line"]
        let c = ProbeParser.flows(lines).sockets
        #expect(c.count == 2)
        #expect(c["192.0.2.1:40000>192.0.2.9:443"]?.counts == ByteCounts(received: 1000, sent: 100))
        #expect(c["192.0.2.1:40001>192.0.2.9:443"]?.counts == nil)
        var later = c
        later["192.0.2.1:40000>192.0.2.9:443"]?.counts = ByteCounts(received: 5000, sent: 300)
        // A connection opened since counts with all it moved.
        let opened = SocketCounter(pid: 201, name: "curl", proto: "TCP", local: "192.0.2.1:40002", peer: "192.0.2.9:443",
                                   counts: ByteCounts(received: 2000, sent: 0))
        later[opened.key] = opened
        let rates = FlowRates.sockets(later, previous: c, seconds: 2, isNew: { _ in true })
        #expect(rates?["192.0.2.1:40000>192.0.2.9:443"] == ByteRates(received: 2000, sent: 100))
        #expect(FlowRates.perProcess(rates ?? [:], sockets: later)[201] == ByteRates(received: 3000, sent: 100))
        // An old connection seen for the first time is a baseline, not a burst of its lifetime total.
        let baseline = FlowRates.sockets(later, previous: c, seconds: 2)
        #expect(baseline?[opened.key] == ByteRates(received: 0, sent: 0))
        // The same connection reported under another pid (shared socket) continues.
        var moved = later
        moved["192.0.2.1:40000>192.0.2.9:443"]?.pid = 202
        #expect(FlowRates.sockets(moved, previous: c, seconds: 2)?["192.0.2.1:40000>192.0.2.9:443"] == ByteRates(received: 2000, sent: 100))
        #expect(FlowRates.sockets(["x": SocketCounter(pid: 1, name: "", proto: "TCP", local: "", peer: "", counts: nil)],
                                  previous: [:], seconds: 2) == nil)
    }

    /// ss, lsof and nettop write endpoints differently; they must name the same connection.
    @Test func endpointSpellings() {
        #expect(ConnectionTraffic.normalize("192.0.2.1:22") == "192.0.2.1:22")
        #expect(ConnectionTraffic.normalize("[::1]:22") == "[::1]:22")
        #expect(ConnectionTraffic.normalize("::1.22") == "[::1]:22")
        #expect(ConnectionTraffic.normalize("[::ffff:192.0.2.1]:22") == "192.0.2.1:22")
        #expect(ConnectionTraffic.normalize("::ffff:192.0.2.1:22") == "192.0.2.1:22")
        #expect(ConnectionTraffic.normalize("*.*") == "*:*")
        #expect(ConnectionTraffic.normalize("*.5353") == "*:5353")
        #expect(ConnectionTraffic.normalize("::ffff:192.0.2.1.443") == "192.0.2.1:443")
        let c = ConnectionTraffic(proto: "TCP", state: "ESTAB", local: "192.0.2.1:5000", peer: "[2001:db8::1]:443", pid: 1, processName: "x")
        #expect(c.peerHost == "2001:db8::1" && c.peerPort == 443)
        #expect(ServicePorts.name(c.peerPort) == "HTTPS")
    }

    // MARK: Host traffic

    @Test func trafficSources() {
        let hogs = ProbeParser.nethogs([
            "/usr/bin/curl/1234/1000\t1.5\t100.0",
            "/opt/my app/bin/sync/77/0\t0\t2",
            "unknown TCP/0/0\t0.1\t0.1",
            "Waiting for first packet to arrive (see sourceforge.net bug 1019381)",
        ])
        #expect(hogs.map(\.pid) == [1234, 77])
        #expect(hogs[0].name == "curl" && hogs[0].received == 102_400 && hogs[0].sent == 1536)
        #expect(hogs[1].name == "sync")

        let top = ProbeParser.flows(["P\t4321\tGoogle Chrome H\t1000\t10", "F\t4321\tGoogle Chrome H\tUDP\t*:*\t*:*\t\t"])
        #expect(top.processes[4321]?.name == "Google Chrome H")
        #expect(top.sockets.first?.value.counts == nil)

        let counts = ProbeParser.socketCounts([
            #"tcp ESTAB 0 0 192.0.2.1:22 192.0.2.5:5000 users:(("sshd",pid=10,fd=3),("sshd",pid=11,fd=3))"#,
            #"tcp ESTAB 0 0 192.0.2.1:22 192.0.2.5:5001 users:(("sshd",pid=10,fd=4))"#,
            "tcp 0 0 192.0.2.1:80 192.0.2.7:6000 ESTABLISHED 99/nginx",
        ])
        #expect(counts.first { $0.pid == 10 }?.connections == 2)
        #expect(counts.first { $0.pid == 11 }?.connections == 1)
        #expect(counts.first { $0.pid == 99 }?.name == "nginx")
    }

    /// The traffic list stays calm: totals order it, quiet processes stay a minute, then go.
    @MainActor @Test func trafficListIsSteady() {
        let t = ProcessTraffic(executor: RemoteExecutor(target: .local, options: SSHOptions()))
        func flows(_ a: Int64, _ b: Int64) -> String {
            "@@flows\nF\t1\tapp\tTCP\t192.0.2.1:1\t192.0.2.2:443\t\(a)\t0\nF\t2\tsync\tTCP\t192.0.2.1:2\t192.0.2.3:22\t\(b)\t0\n"
        }
        t.ingest("@@source\ntcp\n", at: now)
        t.ingest(flows(0, 0), at: now)
        t.ingest(flows(10_000, 2_000), at: now.addingTimeInterval(2))
        t.ingest(flows(10_000, 40_000), at: now.addingTimeInterval(4))   // app quiet, sync busy
        #expect(t.entries.map(\.pid) == [2, 1])                          // by total: sync moved more
        #expect(t.entries.first { $0.pid == 1 }?.rate == 0)               // quiet, still listed
        #expect(t.entries.first { $0.pid == 1 }?.totalReceived == 10_000)
        t.ingest(flows(10_000, 40_000), at: now.addingTimeInterval(70))
        #expect(t.entries.isEmpty)                                         // both quiet for over a minute
        #expect(ProcessTraffic.installSuggestion(osID: "ubuntu") == "sudo apt install iproute2 nethogs")
        #expect(ProcessTraffic.installSuggestion(osID: "rocky")?.contains("epel-release") == true)
        #expect(ProcessTraffic.installSuggestion(osID: "plan9") == nil)
    }

    @MainActor @Test func trafficStreamRecords() {
        let t = ProcessTraffic(executor: RemoteExecutor(target: .local, options: SSHOptions()))
        t.ingest("@@source\nnettop\n", at: now)
        #expect(t.source == .nettop)
        t.ingest("@@flows\nP\t5\tapp\t1000\t0\nF\t5\tapp\tTCP\t192.0.2.1:1\t192.0.2.2:443\t1000\t0\n", at: now)
        t.ingest("@@flows\nP\t5\tapp\t3000\t500\nF\t5\tapp\tTCP\t192.0.2.1:1\t192.0.2.2:443\t3000\t500\n", at: now.addingTimeInterval(2))
        #expect(t.entries.first?.received == 1000 && t.entries.first?.sent == 250)
        #expect(t.entries.first?.flows.first?.received == 1000)
        #expect(t.entries.first?.flows.first?.peerPort == 443)
        t.ingest("@@source\nnethogs\n", at: now)
        t.ingest("@@nethogs\nAdding local address: 192.0.2.1\n@@failed\n", at: now)
        #expect(t.message?.contains("nethogs could not capture") == true)
        t.ingest("@@source\nconnections\n", at: now)
        #expect(t.source == .connections)
        #expect(t.rates(for: [5]) == nil)
    }
}
