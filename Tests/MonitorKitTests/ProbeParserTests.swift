import Foundation
import Testing
@testable import MonitorKit

@Suite struct ProbeParserTests {
    let linux = """
    @@uname
    web-1
    6.8.0-45-generic
    x86_64
    @@os
    Ubuntu 24.04.1 LTS
    @@uptime
    86500.12
    @@load
    0.50 0.40 0.30
    @@ncpu
    4
    @@cpu
    cpu  100 0 100 800 0 0 0 0 0 0
    cpu  150 0 150 900 0 0 0 0 0 0
    @@meminfo
    MemTotal:        8000000 kB
    MemFree:         1000000 kB
    MemAvailable:    6000000 kB
    SwapTotal:       2000000 kB
    SwapFree:        1500000 kB
    @@disk
    /dev/sda1 100000 40000 60000 40% /
    tmpfs 1000 0 1000 0% /run
    @@end
    """

    @Test func parsesLinuxSnapshot() {
        let s = ProbeParser.system(linux, previous: nil)
        #expect(s.hostname == "web-1")
        #expect(s.osName == "Ubuntu 24.04.1 LTS")
        #expect(s.cpuCount == 4)
        #expect(s.load == [0.5, 0.4, 0.3])
        #expect(abs((s.cpuUsage ?? 0) - 0.5) < 0.001)
        #expect(s.memTotal == 8_000_000 * 1024)
        #expect(s.memUsed == 2_000_000 * 1024)
        #expect(s.swapUsed == 500_000 * 1024)
        #expect(s.disks.map(\.mount) == ["/"])
    }

    @Test func parsesProcesses() {
        let text = "    1 root      0.0  0.1  1234 01:02:03 /sbin/init splash\n  42 www   12.5  3.0 99999    05:00 nginx: worker process\n"
        let p = ProbeParser.processes(text)
        #expect(p.count == 2)
        #expect(p[1].pid == 42)
        #expect(p[1].cpu == 12.5)
        #expect(p[1].command == "nginx: worker process")
        #expect(p[0].name == "init")
    }

    @Test func parsesConnections() {
        let text = """
        @@who
        alice    pts/0        2026-01-01 10:00 (192.0.2.10)
        @@ss
        0 0 192.0.2.1:22 192.0.2.10:51000 users:(("sshd",pid=1,fd=4))
        0 0 192.0.2.1:443 198.51.100.7:40000
        @@end
        """
        let r = ProbeParser.connections(text)
        #expect(r.logins.first?.from == "192.0.2.10")
        #expect(r.connections.count == 2)
        #expect(r.connections[0].isSSH)
        #expect(r.connections[0].process == "sshd")
    }

    @Test func parsesRemoteSessions() {
        let text = """
        @@tmux
        tether-abc|1700000000|0
        work|1700000000|1
        @@screen
        There are screens on:
        \t1234.tether-def\t(Detached)
        @@end
        """
        let all = ProbeParser.remoteSessions(text)
        #expect(all.map(\.name) == ["tether-abc", "work", "tether-def"])
        #expect(all.filter(\.isTether).count == 2)
        let tether = ProbeParser.remoteSessions(text, prefix: "tether-")
        #expect(tether.map(\.name) == ["tether-abc", "tether-def"])
        #expect(tether[0].attached == false)
    }

    @Test func parsesTmuxPanesWithForegroundCommands() {
        let text = """
        @@tmux
        work|1700000000|0|3
        build|1700000000|1|1
        @@tmuxpanes
        work|0|editor|0|1|%1|/dev/pts/3|vim|/home/user/src
        work|1|train|1|0|%2|/dev/pts/4|bash|/srv/ml
        work|1|train|1|1|%3|/dev/pts/5|python3|/srv/ml/a|b
        work|2|idle|0|1|%4|/dev/pts/6|zsh|/home/user
        build|0|make|1|1|%5|/dev/ttys007|make|/Users/user/project
        @@tmuxtitles
        %1|host.example.com|host.example.com
        %4|host.example.com|user@host: ~
        @@fg
        101 pts/3 S+ vim main.go
        102 pts/4 Ss+ -bash
        103 pts/5 Ss bash
        104 pts/5 Rl+ /usr/bin/python3 train.py --epochs 3
        105 ttys007  S+   make -j8 all
        @@agents
        @@screen
        @@end
        """
        let all = ProbeParser.remoteSessions(text)
        let work = all[0], build = all[1]
        #expect(work.panes.count == 4)
        #expect(work.activePane?.windowName == "train")
        #expect(work.activePane?.commandLine == "/usr/bin/python3 train.py --epochs 3")
        #expect(work.activePane?.path == "/srv/ml/a|b")
        #expect(work.panes[0].displayCommand == "vim main.go")
        #expect(work.panes[1].isShell && work.panes[1].commandLine == nil)
        #expect(work.panes[3].summary == "zsh — /home/user")
        #expect(build.activePane?.commandLine == "make -j8 all")
        #expect(work.panes[0].title.isEmpty)
        #expect(work.panes[3].title == "user@host: ~")
    }

    @Test func namesCodingAgentSessions() {
        let text = #"""
        @@tmux
        agents|1700000000|0|4
        @@tmuxpanes
        agents|0|claude|1|1|%1|/dev/pts/1|claude|/srv/app
        agents|1|codex|0|1|%2|/dev/pts/2|codex|/srv/api
        agents|2|node|0|1|%3|/dev/pts/3|node|/srv/web
        agents|3|opencode|0|1|%4|/dev/pts/4|opencode|/srv/docs
        @@tmuxtitles
        %3|host.example.com|⠂ Codex
        %4|host.example.com|✳ Write the changelog
        @@fg
        201 pts/1 Sl+ claude
        202 pts/2 Sl+ codex resume 11111111-2222-3333-4444-555555555555
        203 pts/3 Sl+ node /usr/lib/node_modules/@openai/codex/bin/codex.js
        204 pts/3 Sl+ /usr/lib/node_modules/@openai/codex/vendor/codex
        205 pts/4 Sl+ opencode
        @@agents
        201|claude|json|{"name":"Fix \"login\" bug","nameSource":"user","status":"busy"}
        201|claude|found|
        202|codex|index|{"id":"11111111-2222-3333-4444-555555555555","thread_name":"Release prep","updated_at":"2026-10-01T00:00:00Z"}
        202|codex|title|Generated title
        202|codex|found|
        203|codex|found|
        204|codex|found|
        205|opencode|found|
        @@end
        """#
        let panes = ProbeParser.remoteSessions(text)[0].panes
        #expect(panes[0].agent == CodingAgent(kind: .claude, sessionName: "Fix \"login\" bug", namedByUser: true, status: "busy"))
        #expect(panes[0].agent?.isWorking == true)
        #expect(panes[0].displayCommand == "Claude Code: Fix \"login\" bug")
        #expect(panes[1].agent?.sessionName == "Release prep" && panes[1].agent?.namedByUser == true)
        // No name known and the title only says "Codex": just the agent.
        #expect(panes[2].agent?.kind == .codex)
        #expect(panes[2].displayCommand == "Codex")
        // opencode without its database: the terminal title stands in.
        #expect(panes[3].summary == "opencode: Write the changelog — /srv/docs")
    }

    /// Claude Code names its tmux pane; that wins even when the foreground process is something else.
    @Test func claudeFoundByItsTmuxPane() {
        let text = #"""
        @@tmux
        work|1700000000|0|1
        @@tmuxpanes
        work|0|main|1|1|%7|/dev/pts/9|bash|/srv/app
        @@fg
        301 pts/9 Ss+ -bash
        @@agents
        455|claude|json|{"name":"Ship it","nameSource":"auto","status":"idle","tmux":"work:@3.%7"}
        455|claude|found|
        @@end
        """#
        let pane = ProbeParser.remoteSessions(text)[0].panes[0]
        #expect(pane.agent?.sessionName == "Ship it")
        #expect(pane.agent?.namedByUser == false && pane.agent?.isWorking == false)
        #expect(pane.displayCommand == "Claude Code: Ship it")
    }

    @Test func remoteSessionsWithoutPaneSections() {
        let all = ProbeParser.remoteSessions("@@tmux\nwork|1700000000|0|1\n@@end\n")
        #expect(all.count == 1)
        #expect(all[0].panes.isEmpty && all[0].activePane == nil)
        #expect(RemoteSessionPane(windowIndex: 0, windowName: "", windowActive: true, paneActive: true,
                                  command: "-zsh", commandLine: nil, path: "").isShell)
    }

    @Test func parsesNvidiaIncludingUnifiedMemory() {
        let lines = ["0, NVIDIA GB10, 37, [N/A], [N/A], 51, 18.42, [N/A]",
                     "1, NVIDIA A100-SXM4-80GB, 99, 40000, 81920, 70, 300.5, 400.00"]
        let g = ProbeParser.gpus(nvidia: lines, rocm: nil, amdSysfs: nil)
        #expect(g.count == 2)
        #expect(g[0].name == "NVIDIA GB10")
        #expect(abs((g[0].utilization ?? 0) - 0.37) < 0.001)
        #expect(g[0].memoryTotal == nil && g[0].memoryFraction == nil)
        #expect(g[0].temperature == 51)
        #expect(g[1].memoryTotal == Int64(81920) * 1_048_576)
        #expect(g[1].powerLimit == 400)
    }

    @Test func parsesAMDSysfs() {
        let g = ProbeParser.gpus(nvidia: nil, rocm: nil, amdSysfs: ["0|12|1073741824|8589934592|45000|35000000"])
        #expect(g.first?.vendor == .amd)
        #expect(g.first?.temperature == 45)
        #expect(g.first?.power == 35)
        #expect(abs((g.first?.memoryFraction ?? 0) - 0.125) < 0.001)
    }

    @Test func sshDetectionUsesSshdPorts() {
        let text = """
        @@sshports
        0.0.0.0:2222
        cfg:2222
        @@conn
        198.51.100.4 50122 192.0.2.1 2222
        @@ss
        0 0 192.0.2.1:2222 198.51.100.4:50122
        0 0 192.0.2.1:22 203.0.113.9:40000
        @@end
        """
        let r = ProbeParser.connections(text)
        #expect(r.connections.first { $0.local.hasSuffix(":2222") }?.isSSH == true)
        #expect(r.connections.first { $0.local.hasSuffix(":22") }?.isSSH == false)
    }

    @Test func parsesServicesAndContainers() {
        let svc = ProbeParser.services("""
        @@systemd
        ssh.service loaded active running OpenBSD Secure Shell server
        nginx.service loaded failed failed A high performance web server
        """)
        #expect(svc.count == 2)
        #expect(svc[0].isRunning && svc[1].isFailed)
        let c = ProbeParser.containers("@@docker\nabc123\tnginx:latest\tweb\tUp 2 hours\trunning\t0.0.0.0:80->80/tcp\n")
        #expect(c.first?.name == "web" && c.first?.isRunning == true && c.first?.engine == "docker")
    }

    @Test func parsesConnectionInfo() {
        let text = "@@conn\n198.51.100.4 50122 192.0.2.1 2222\n@@ips\n192.0.2.1\n10.0.0.5\n@@sshports\ncfg:2222\n@@end\n"
        let s = ProbeParser.system(text, previous: nil)
        #expect(s.connection?.serverPort == "2222")
        #expect(s.connection?.addresses == ["192.0.2.1", "10.0.0.5"])
        #expect(s.connection?.sshPorts == ["2222"])
    }

    @Test func networkRatesAndOrdering() {
        let first = """
        @@netdev
        lo 1000 1000
        docker0 0 0
        eth0 1000000 500000
        veth12ab 10 10
        @@netinfo
        lo|unknown|00:00:00:00:00:00|0|0
        docker0|down|02:42:ac:11:00:01||0
        eth0|up|52:54:00:12:34:56|1000|1
        veth12ab|up|aa:bb:cc:dd:ee:ff|10000|0
        @@netaddr
        eth0 192.0.2.10/24
        eth0 fe80::1/64
        @@end
        """
        let a = ProbeParser.system(first, previous: nil)
        #expect(a.interfaces.first?.name == "eth0")
        #expect(a.interfaces.first?.addresses == ["192.0.2.10/24"])
        #expect(a.interfaces.first?.speedMbps == 1000)
        // Two seconds later, eth0 received 2 MB and sent 1 MB.
        var earlier = a
        earlier.timestamp = Date().addingTimeInterval(-2)
        let b = ProbeParser.system("@@netdev\neth0 3000000 1500000\nlo 2000 2000\n@@end\n", previous: earlier)
        let eth = b.interfaces.first { $0.name == "eth0" }
        #expect(eth?.isPhysical == true && eth?.mac == "52:54:00:12:34:56")
        #expect(abs((eth?.rxRate ?? 0) - 1_000_000) < 50_000)
        #expect(abs((b.networkRates?.tx ?? 0) - 500_000) < 25_000)
    }

    @Test func listeningSocketsWithExposureAndContainers() {
        let containers = ProbeParser.containers(
            "@@docker\nabc\tgrafana/grafana\tgrafana\tUp 3 days\trunning\t0.0.0.0:3000->3000/tcp, :::3000->3000/tcp\n"
            + "def\tpostgres:16\tdb\tUp 3 days\trunning\t127.0.0.1:5432->5432/tcp\n"
            + "ghi\tredis\tcache\tExited (0)\texited\t6379/tcp\n")
        #expect(containers.first { $0.name == "grafana" }?.portMappings.count == 1)
        #expect(containers.first { $0.name == "grafana" }?.portMappings.first?.exposure == .allInterfaces)
        #expect(containers.first { $0.name == "db" }?.portMappings.first?.exposure == .localOnly)
        #expect(containers.first { $0.name == "cache" }?.portMappings.first?.isPublished == false)

        let text = """
        tcp\t0.0.0.0:22\tsshd\t812
        tcp\t[::]:22\tsshd\t812
        tcp\t127.0.0.1:5432\tdocker-proxy\t2001
        tcp\t0.0.0.0:3000\tdocker-proxy\t2002
        tcp\t192.0.2.10:8080\tnginx\t900
        udp\t0.0.0.0:53\t\t
        """
        let l = ProbeParser.listening(text, containers: containers)
        #expect(l.count == 5)
        #expect(l.first { $0.port == 22 }?.exposure == .allInterfaces)
        #expect(l.first { $0.port == 3000 }?.container == "grafana")
        #expect(l.first { $0.port == 5432 }?.exposure == .localOnly)
        #expect(l.first { $0.port == 8080 }?.exposure == .interface)
        #expect(l.first { $0.port == 22 }?.pid == 812)
        #expect(l.last?.exposure == .localOnly)
    }
}

@Suite struct WindowsParserTests {
    @Test func windowsServices() {
        let text = "@@winsvc\nsshd|Running|Automatic|OpenSSH SSH Server\nSpooler|Stopped|Disabled|Print Spooler\nW32Time|StartPending|Manual|Windows Time\n"
        let s = ProbeParser.services(text)
        #expect(s.count == 3)
        #expect(s[0].name == "sshd" && s[0].active == "active" && s[0].description == "OpenSSH SSH Server")
        #expect(s[1].active == "inactive" && s[1].load == "disabled")
        #expect(s[2].active == "activating")
    }

    @Test func windowsListeningSocketsWithIPv6() {
        let text = "tcp\t0.0.0.0:22\tsshd\t3120\ntcp\t[::]:22\tsshd\t3120\ntcp\t127.0.0.1:5432\tpostgres\t880\nudp\t[::1]:53\tdns\t9\n"
        let l = ProbeParser.listening(text)
        #expect(l.contains { $0.port == 22 && $0.process == "sshd" })
        #expect(l.first { $0.port == 5432 }?.address == "127.0.0.1")
    }

    @Test func windowsSystemFrame() {
        let frame = """
        @@uname
        WIN-DEMO
        10.0.20348
        AMD64
        @@os
        Microsoft Windows Server 2022 Datacenter
        @@osinfo
        id=windows
        version=10.0.20348
        @@uptime
        86400
        @@ncpu
        8
        @@cpupct
        CPU usage: 25% user, 0% sys, 75% idle
        @@meminfo
        MemTotal: 16777216 kB
        MemAvailable: 8388608 kB
        SwapTotal: 4194304 kB
        SwapFree: 4194304 kB
        @@disk
        C: 104857600 52428800 52428800 50% C:/
        """
        let s = ProbeParser.system(frame, previous: nil)
        #expect(s.hostname == "WIN-DEMO" && s.osName.contains("Windows"))
        #expect(abs((s.cpuUsage ?? 0) - 0.25) < 0.001)
        #expect(abs(s.memFraction - 0.5) < 0.001)
        #expect(s.load.isEmpty)
        #expect(s.disks.first?.mount == "C:/")
    }
}

@Suite struct DiskUsageTests {
    @Test func macOSShowsContainerUsageLikeFinder() {
        let frame = """
        @@darwinmem
        68719476736
        @@disk
        /dev/disk3s1s1   971350180  13333684 179974488     7%    /
        /dev/disk3s5     971350180 764605392 179974488    81%    /System/Volumes/Data
        devfs                  201       201         0   100%    /dev
        """
        let s = ProbeParser.system(frame, previous: nil)
        #expect(s.disks.count == 1)
        let root = s.disks[0]
        #expect(root.mount == "/")
        #expect(abs(root.fraction - 0.815) < 0.01, "got \(root.fraction)")
    }

    @Test func linuxMatchesDfCapacity() {
        let frame = """
        @@disk
        /dev/sda1 100000 90000 5000 95% /
        """
        let s = ProbeParser.system(frame, previous: nil)
        #expect(abs((s.disks.first?.fraction ?? 0) - 90000.0 / 95000.0) < 0.001)
    }
}
