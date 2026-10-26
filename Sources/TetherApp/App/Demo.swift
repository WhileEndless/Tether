#if DEBUG
import AppKit
import ScreenCaptureKit
import TetherCore
import SessionKit
import MonitorKit
import TerminalUI

/// Debug-only demo with entirely synthetic hosts, terminals, files and metrics, used for the
/// screenshots in the README (`make demo`). It refuses to run unless every location Tether
/// would touch is redirected, so real settings, hosts, keychain items and recordings are never
/// read or changed:
///
///     TETHER_DEMO=<empty dir>  TETHER_SUPPORT_DIR=<dir>  TETHER_DEFAULTS_SUITE=<name>
///     TETHER_SSH_CONFIG=<TETHER_DEMO>/ssh_config  TETHER_DEMO_TMUX=<short dir for tmux sockets>
///
/// "ssh" is a script that never opens a network connection: terminals run a tiny shell that
/// prints prepared output inside a private tmux server, and file listings run against a fake
/// server tree inside the demo folder.
@MainActor
enum DemoMode {
    /// The name shown for this Mac: a made-up one in the demo, so screenshots never show the real one.
    nonisolated static var localMachineName: String? {
        ProcessInfo.processInfo.environment["TETHER_DEMO"] == nil ? nil : "demo-mac.local"
    }

    private static var started = false

    static var directory: URL? {
        ProcessInfo.processInfo.environment["TETHER_DEMO"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Writes the demo files and points the settings at them. Runs before anything reads settings.
    static func prepareIfRequested() {
        guard let dir = directory else { return }
        let env = ProcessInfo.processInfo.environment
        guard env["TETHER_SUPPORT_DIR"] != nil, env["TETHER_DEFAULTS_SUITE"] != nil,
              env["TETHER_SSH_CONFIG"] == dir.appendingPathComponent("ssh_config").path,
              let tmux = env["TETHER_DEMO_TMUX"] else {
            fatalError("Demo mode needs TETHER_SUPPORT_DIR, TETHER_DEFAULTS_SUITE, TETHER_SSH_CONFIG and TETHER_DEMO_TMUX (use `make demo`).")
        }
        do {
            try DemoFiles.write(to: dir, tmuxDirectory: tmux)
        } catch {
            fatalError("Could not write demo files: \(error)")
        }
        let store = SettingsStore.shared
        store.settings.sshBinary = dir.appendingPathComponent("bin/ssh").path
        store.settings.scpBinary = dir.appendingPathComponent("bin/ssh").path
        store.settings.sshConfigPath = dir.appendingPathComponent("ssh_config").path
        store.settings.useControlMaster = false
        store.settings.recordingEnabled = false
        store.settings.restoreSessionsOnLaunch = false
        store.settings.confirmCloseOnlineSessions = false
        store.settings.showStatusStrip = true
        store.settings.showSidebarArchive = false
        store.settings.defaultPersistence = .tmux
        // TETHER_DEMO_LOOK=style,appearance[,size] (e.g. folders,light,large) for screenshots of the
        // appearance choices.
        let look = (env["TETHER_DEMO_LOOK"] ?? "").split(separator: ",").map(String.init)
        if let style = look.first.flatMap(SidebarStyle.init(rawValue:)) { store.settings.sidebarStyle = style }
        if look.count > 1, let appearance = AppAppearance(rawValue: look[1]) { store.settings.appearance = appearance }
        if look.count > 2, let size = UITextSize(rawValue: look[2]) { store.settings.uiTextSize = size }
    }

    /// Fills the first window: host groups, terminals, a file manager tab and host metrics.
    static func runIfRequested(state: WindowState) {
        guard !started, let dir = directory else { return }
        started = true
        let model = AppModel.shared

        // Groups and colors.
        let groups: [(String, TagColor, [String])] = [
            ("Production", .orange, ["bastion", "web-01", "web-02", "db-primary"]),
            ("Machine Learning", .purple, ["gpu-01"]),
            ("Staging", .green, ["staging"]),
        ]
        for (name, color, hosts) in groups {
            model.addGroup(named: name)
            guard let group = model.library.groups.last else { continue }
            model.updateGroup(group.id) { $0.color = color }
            for h in hosts {
                model.moveHost(h, toGroup: group.id)
                model.updateMetadata(for: h) { $0.keyLoginWorks = true; $0.color = color }
            }
        }
        for (host, data) in DemoFiles.monitors() {
            model.monitor(for: .alias(host)).loadDemo(data)
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            state.window?.setFrame(NSRect(x: 80, y: 80, width: 1440, height: 900), display: true)
            let tabs: [(String, String)] = [("web-01", "deploy"), ("gpu-01", "training"), ("db-primary", "psql"), ("web-02", "logs")]
            var first: TerminalSession?
            for (host, title) in tabs {
                let s = state.connect(.alias(host))
                model.sessions.rename(s.id, to: title)
                if first == nil { first = s }
                try? await Task.sleep(for: .seconds(0.6))
            }
            state.openFiles(.alias("web-01"), path: "/srv/shop")
            try? await Task.sleep(for: .seconds(1.5))
            if let first { state.select(first) }
            state.sidebarSelection = first.map { .session($0.id) }
            state.inspectorTab = .overview
            state.showInspectorRequest = true
            try? await Task.sleep(for: .seconds(2))
            writeWindowList(to: dir)
            if ProcessInfo.processInfo.environment["TETHER_DEMO_SHOTS"] != nil, let first {
                await takeScreenshots(state: state, main: first, dir: dir)
            }
        }
    }

    // MARK: Screenshots

    /// Walks through a few scenes and saves each window with ScreenCaptureKit (needs the Screen
    /// Recording permission for the demo app only; asked for once).
    static func takeScreenshots(state: WindowState, main: TerminalSession, dir: URL) async {
        let model = AppModel.shared
        let out = dir.appendingPathComponent("shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            log("needs-permission", dir)
            return
        }
        let tabs = state.tabs
        func session(_ title: String) -> TerminalSession? { tabs.first { $0.displayTitle == title } }
        func scene(_ name: String, _ tab: TerminalSession?, _ inspector: InspectorTab) async {
            // Inactive windows are drawn without accent colors; capture the window as it looks in use.
            NSApp.activate()
            state.window?.makeKeyAndOrderFront(nil)
            if let tab { state.select(tab); state.sidebarSelection = .session(tab.id) }
            state.inspectorTab = inspector
            try? await Task.sleep(for: .seconds(2.5))
            await shoot(state.window, name, out, dir)
        }
        await scene("terminal", main, .overview)
        await scene("gpu", session("training"), .gpu)
        await scene("ports", main, .ports)
        await scene("containers", main, .containers)
        await scene("processes", session("psql"), .processes)
        await scene("sudo", session("logs"), .overview)
        if case .files(let ft)? = state.items.first(where: { if case .files = $0 { true } else { false } }) {
            state.select(ft.id)
            state.sidebarSelection = nil
            state.inspectorTab = .services
            try? await Task.sleep(for: .seconds(2.5))
            await shoot(state.window, "files", out, dir)
        }
        state.select(main)
        model.searchPreset = SearchPreset(host: nil, session: nil, query: "checkout")
        model.openSearch?()
        try? await Task.sleep(for: .seconds(1))
        NSApp.activate()
        NSApp.windows.first { $0.title == "Search" }?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(2))
        await shoot(NSApp.windows.first { $0.title == "Search" && $0.isVisible }, "search", out, dir)
        log("done", dir)
    }

    private static func shoot(_ window: NSWindow?, _ name: String, _ out: URL, _ dir: URL) async {
        guard let window else { log("\(name): no window", dir); return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let w = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                log("\(name): window not shareable", dir)
                return
            }
            let config = SCStreamConfiguration()
            config.width = Int(w.frame.width * window.backingScaleFactor)
            config.height = Int(w.frame.height * window.backingScaleFactor)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w),
                                                                   configuration: config)
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
            log("\(name): ok", dir)
        } catch {
            log("\(name): \(error.localizedDescription)", dir)
        }
    }

    private static func log(_ line: String, _ dir: URL) {
        let url = dir.appendingPathComponent("demo.log")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (text + line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Window numbers for `screencapture -l` (the demo is captured from outside the app).
    static func writeWindowList(to dir: URL) {
        let lines = NSApp.windows.filter(\.isVisible).map { "\($0.windowNumber)\t\($0.title)" }
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("windows.txt"), atomically: true, encoding: .utf8)
    }
}

/// The synthetic world of the demo.
enum DemoFiles {
    static func write(to dir: URL, tmuxDirectory: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("screens"), withIntermediateDirectories: true)
        try fm.createDirectory(atPath: tmuxDirectory, withIntermediateDirectories: true)
        try sshConfig.write(to: dir.appendingPathComponent("ssh_config"), atomically: true, encoding: .utf8)
        try executable(fakeSSH(dir.path, tmux: tmuxDirectory), dir.appendingPathComponent("bin/ssh"))
        try executable(demoShell(dir.path), dir.appendingPathComponent("bin/demo-shell"))
        let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].first { fm.isExecutableFile(atPath: $0) } ?? "tmux"
        // One tmux server per demo host, so every host's shell gets its own screen.
        try executable("#!/bin/sh\nexec \(tmux) -f /dev/null -L \"demo-${TETHER_DEMO_HOST:-x}\" \"$@\"\n", dir.appendingPathComponent("bin/tmux"))
        for (host, text) in screens {
            try text.write(to: dir.appendingPathComponent("screens/\(host).txt"), atomically: true, encoding: .utf8)
        }
        try writeServerTree(dir.appendingPathComponent("root"))
    }

    private static func executable(_ text: String, _ url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    static let sshConfig = """
    # Tether demo — synthetic hosts (documentation address ranges, nothing real)

    Host bastion
        HostName 203.0.113.10
        User deploy

    Host web-01
        HostName 10.20.0.11
        User deploy
        ProxyJump bastion

    Host web-02
        HostName 10.20.0.12
        User deploy
        ProxyJump bastion

    Host db-primary
        HostName 10.20.0.21
        User postgres
        ProxyJump bastion

    Host gpu-01
        HostName 198.51.100.40
        User ml
        Port 2222

    Host staging
        HostName staging.example.com
        User deploy

    """

    /// Never connects anywhere. Terminals → private tmux running `demo-shell`;
    /// `sh -s` scripts (file listings) → run against the fake server tree, paths mapped in and out.
    static func fakeSSH(_ d: String, tmux: String) -> String {
        """
        #!/bin/sh
        D=\(d.shellQuoted)
        for a; do case "$a" in -O) exit 1;; esac; done
        host=; take=0
        for a; do if [ $take = 1 ]; then host=$a; take=2; fi; [ "$a" = "--" ] && [ $take = 0 ] && take=1; done
        for last; do :; done
        export HOME="$D/root/home/deploy" USER=deploy LOGNAME=deploy
        TAB=$(printf '\\t')
        case "$last" in
          "sh -s"*)
            eval "set -- $last"; shift 3
            n=$#; i=0
            while [ $i -lt $n ]; do a=$1; shift; case "$a" in /*) a="$D/root$a";; esac; set -- "$@" "$a"; i=$((i+1)); done
            cd "$HOME" || exit 1
            sh -s -- "$@" | sed -e "s#$D/root##g" -e "s/$TAB$(id -un)$TAB$(id -gn)$TAB/${TAB}deploy${TAB}deploy$TAB/"
            ;;
          *7770*)
            export PATH="$D/bin:/usr/bin:/bin" TMUX_TMPDIR=\(tmux.shellQuoted) SHELL="$D/bin/demo-shell" TETHER_DEMO_HOST="$host"
            unset TMUX
            eval "exec $last"
            ;;
          *) exit 0 ;;
        esac
        """
    }

    static func demoShell(_ d: String) -> String {
        """
        #!/bin/sh
        f=\(d.shellQuoted)/screens/"$TETHER_DEMO_HOST".txt
        [ -f "$f" ] && cat "$f"
        while IFS= read -r line; do :; done
        """
    }

    // MARK: Terminal screens

    private static let e = "\u{1b}["
    private static func prompt(_ user: String, _ host: String, _ dir: String) -> String {
        "\(e)1;32m\(user)@\(host)\(e)0m:\(e)1;34m\(dir)\(e)0m$ "
    }

    static var screens: [String: String] {
        let web = prompt("deploy", "web-01", "/srv/shop")
        let gpu = prompt("ml", "gpu-01", "~/runs/llm-ft")
        let db = prompt("postgres", "db-primary", "~")
        let web2 = prompt("deploy", "web-02", "~")
        return [
            "web-01": """
            Welcome to Ubuntu 24.04.1 LTS (GNU/Linux 6.8.0-45-generic x86_64)

             System load:  0.42               Processes:             187
             Usage of /:   38.1% of 96.73GB   Users logged in:       2
             Memory usage: 41%                IPv4 address for eth0: 10.20.0.11

            Last login: Thu Oct 23 09:12:44 2026 from 10.20.0.2
            \(prompt("deploy", "web-01", "~"))cd /srv/shop && git pull --ff-only
            Updating 3f2c1ab..9d41e07
            Fast-forward
             src/api/orders.ts     | 42 \(e)32m++++++++++++++++++++++\(e)31m--------\(e)0m
             src/api/payments.ts   | 17 \(e)32m+++++++++\(e)31m------\(e)0m
             src/web/Checkout.tsx  | 64 \(e)32m++++++++++++++++++++++++++++++\(e)31m-------\(e)0m
             3 files changed, 92 insertions(+), 31 deletions(-)
            \(web)npm run build

            > shop@2.4.0 build
            > vite build

            \(e)36mvite v6.0.3\(e)0m \(e)32mbuilding for production...\(e)0m
            \(e)32m✓\(e)0m 1284 modules transformed.
            \(e)2mdist/\(e)0m\(e)32mindex.html\(e)0m                  \(e)1;2m  0.62 kB\(e)0m\(e)2m │ gzip:   0.38 kB\(e)0m
            \(e)2mdist/\(e)0m\(e)35massets/index-4f1c9a2b.css\(e)0m  \(e)1;2m 38.91 kB\(e)0m\(e)2m │ gzip:   7.12 kB\(e)0m
            \(e)2mdist/\(e)0m\(e)36massets/index-b81e33d0.js\(e)0m   \(e)1;2m412.33 kB\(e)0m\(e)2m │ gzip: 131.02 kB\(e)0m
            \(e)32m✓ built in 6.81s\(e)0m
            \(web)sudo systemctl restart shop-api && systemctl status shop-api --no-pager | head -4
            \(e)1;32m●\(e)0m shop-api.service - Shop API (Node.js)
                 Loaded: loaded (/etc/systemd/system/shop-api.service; \(e)1;32menabled\(e)0m)
                 Active: \(e)1;32mactive (running)\(e)0m since Thu 2026-10-23 09:14:02 UTC; 2s ago
               Main PID: 48211 (node)
            \(web)ls -l
            total 40
            -rw-r--r--   1 deploy deploy  2214 Oct 23 09:13 README.md
            drwxr-xr-x   4 deploy deploy  4096 Oct 23 09:14 \(e)1;34mdist\(e)0m
            drwxr-xr-x 412 deploy deploy 16384 Oct 21 17:40 \(e)1;34mnode_modules\(e)0m
            -rw-r--r--   1 deploy deploy  1187 Oct 23 09:13 package.json
            drwxr-xr-x   2 deploy deploy  4096 Oct 20 11:02 \(e)1;34mscripts\(e)0m
            drwxr-xr-x   5 deploy deploy  4096 Oct 23 09:13 \(e)1;34msrc\(e)0m
            \(web)
            """,
            "gpu-01": """
            \(gpu)python train.py --config configs/llm-ft.yaml
            [2026-10-23 08:01:12] Loading checkpoint shards: \(e)32m100%\(e)0m|██████████| 4/4
            [2026-10-23 08:01:40] Dataset: 412,880 examples · 8 GPUs · bf16
            \(e)1mEpoch 3/5\(e)0m
              step 2400/3200  loss \(e)33m1.284\(e)0m  lr 1.8e-5  tok/s 51,240
              step 2500/3200  loss \(e)33m1.271\(e)0m  lr 1.7e-5  tok/s 51,612
              step 2600/3200  loss \(e)32m1.249\(e)0m  lr 1.6e-5  tok/s 51,488
            eval: \(e)36mppl 3.48\(e)0m  acc 0.712  \(e)32m(best so far, checkpoint saved)\(e)0m
              2650/3200 \(e)35m████████████████████████▎\(e)0m    83% 0:41:12<0:08:31
            """,
            "db-primary": """
            \(db)psql -d shop
            psql (16.4 (Ubuntu 16.4-1.pgdg24.04+1))
            Type "help" for help.

            shop=# SELECT status, count(*), round(avg(total), 2) AS avg_total FROM orders GROUP BY 1 ORDER BY 2 DESC;
              status   | count | avg_total
            -----------+-------+-----------
             delivered | 18422 |     64.18
             shipped   |  1207 |     71.92
             pending   |   318 |     58.40
             refunded  |    96 |     49.75
            (4 rows)

            shop=#
            """,
            "web-02": """
            \(web2)journalctl -u shop-api -f
            Oct 23 09:14:02 web-02 node[48211]: \(e)32mINFO\(e)0m  listening on :8080
            Oct 23 09:14:07 web-02 node[48211]: \(e)32mINFO\(e)0m  GET /api/orders 200 18ms
            Oct 23 09:14:09 web-02 node[48211]: \(e)33mWARN\(e)0m  slow query orders.list 412ms
            Oct 23 09:14:12 web-02 node[48211]: \(e)32mINFO\(e)0m  POST /api/checkout 201 64ms
            Oct 23 09:14:15 web-02 node[48211]: \(e)31mERROR\(e)0m payment gateway timeout (retry 1/3)
            Oct 23 09:14:16 web-02 node[48211]: \(e)32mINFO\(e)0m  POST /api/checkout 201 71ms
            ^C
            \(web2)sudo systemctl restart shop-api
            [sudo] password for deploy: \u{20}
            """,
        ].mapValues { $0.replacingOccurrences(of: "\n", with: "\r\n") }
    }

    // MARK: Server tree for the file manager

    static func writeServerTree(_ root: URL) throws {
        let files: [(String, Int, Double)] = [
            ("srv/shop/README.md", 2_214, 0.1), ("srv/shop/package.json", 1_187, 0.1), ("srv/shop/tsconfig.json", 512, 30),
            ("srv/shop/.env.example", 340, 60), ("srv/shop/src/api/orders.ts", 8_420, 0.1), ("srv/shop/src/api/payments.ts", 5_310, 0.1),
            ("srv/shop/src/web/Checkout.tsx", 12_904, 0.1), ("srv/shop/dist/index.html", 620, 0.05),
            ("srv/shop/dist/assets/index-b81e33d0.js", 412_330, 0.05), ("srv/shop/scripts/deploy.sh", 1_420, 3),
            ("srv/shop/scripts/backup-db.sh", 980, 12), ("srv/shop/node_modules/.package-lock.json", 182_000, 2),
            ("srv/shop/logs/access.log", 4_812_331, 0.01), ("srv/shop/logs/error.log", 24_410, 0.02),
            ("home/deploy/notes.txt", 420, 4), ("home/deploy/.bashrc", 3_771, 200), ("home/deploy/backups/shop-2026-10-22.sql.gz", 48_220_113, 1),
            ("var/log/syslog", 1_203_441, 0.01),
        ]
        let fm = FileManager.default
        let now = Date()
        for (path, size, daysAgo) in files {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: Data(count: min(size, 64)))
                if size > 64, let h = FileHandle(forWritingAtPath: url.path) { try h.truncate(atOffset: UInt64(size)); try h.close() }
            }
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: url.path)
        }
    }

    // MARK: Host metrics (in the real probe output formats)

    struct Box {
        var name: String, os: String, id: String, version: String, codename: String, kernel: String, hardware: String
        var cpuModel: String, ncpu: Int, memGB: Double, memUsed: Double, load: String, uptimeDays: Double
        var disks: [(String, Double, Double, String)]   // fs, size GB, used fraction, mount
        var ifaces: [(String, String, Int, Bool, String)] // name, mac, speed, physical, address
        var address: String
        var nvidia: [String] = []
    }

    static func frame(_ b: Box) -> String {
        var t = "@@uname\n\(b.name)\n\(b.kernel)\nx86_64\n@@os\n\(b.os)\n@@osinfo\nid=\(b.id)\nversion=\(b.version)\ncodename=\(b.codename)\n"
        t += "kernelbuild=#45-Ubuntu SMP PREEMPT_DYNAMIC\nvirt=kvm\nhardware=\(b.hardware)\nsockets=1\nshell=/bin/bash\n"
        t += "@@cpumodel\n \(b.cpuModel)\n@@ips\n\(b.address)\n@@sshports\ncfg:22\n@@conn\n10.20.0.2 51522 \(b.address) 22\n"
        t += "@@uptime\n\(Int(b.uptimeDays * 86_400))\n@@load\n\(b.load)\n@@ncpu\n\(b.ncpu)\n@@cpu\ncpu 1000 0 500 8500 0 0 0 0\n"
        let total = Int(b.memGB * 1_048_576)
        t += "@@meminfo\nMemTotal: \(total) kB\nMemAvailable: \(Int(Double(total) * (1 - b.memUsed))) kB\nSwapTotal: 4194300 kB\nSwapFree: 4012000 kB\n"
        t += "@@disk\n"
        for (fs, gb, used, mount) in b.disks {
            let size = Int(gb * 1_048_576), u = Int(gb * 1_048_576 * used)
            t += "\(fs) \(size) \(u) \(size - u) \(Int(used * 100))% \(mount)\n"
        }
        t += "@@netdev\n"
        for (i, f) in b.ifaces.enumerated() { t += "\(f.0) \(9_000_000_000 / (i + 1)) \(4_000_000_000 / (i + 1))\n" }
        t += "@@netinfo\n"
        for f in b.ifaces { t += "\(f.0)|up|\(f.1)|\(f.2)|\(f.3 ? 1 : 0)\n" }
        t += "@@netaddr\n"
        for f in b.ifaces where !f.4.isEmpty { t += "\(f.0) \(f.4)\n" }
        if !b.nvidia.isEmpty { t += "@@nvidia\n" + b.nvidia.joined(separator: "\n") + "\n" }
        return t
    }

    static func wave(_ n: Int, base: Double, amp: Double, phase: Double = 0) -> [Double] {
        (0..<n).map { i -> Double in
            let x = Double(i)
            let slow: Double = amp * sin(x / 4 + phase)
            let fast: Double = amp * 0.4 * sin(x / 1.3)
            return max(0.01, min(0.99, base + slow + fast))
        }
    }

    static func monitors() -> [String: RemoteMonitor.DemoData] {
        let ubuntu = ("Ubuntu 24.04.1 LTS", "ubuntu", "24.04", "noble", "6.8.0-45-generic")
        func box(_ name: String, _ addr: String, cpus: Int, mem: Double, used: Double, load: String) -> Box {
            Box(name: name, os: ubuntu.0, id: ubuntu.1, version: ubuntu.2, codename: ubuntu.3, kernel: ubuntu.4,
                hardware: "QEMU Standard PC (Q35 + ICH9, 2009)", cpuModel: "AMD EPYC 9354P 32-Core Processor", ncpu: cpus,
                memGB: mem, memUsed: used, load: load, uptimeDays: 41.3,
                disks: [("/dev/vda1", 96.7, 0.38, "/"), ("/dev/vdb1", 500, 0.62, "/srv")],
                ifaces: [("eth0", "52:54:00:12:34:56", 10_000, true, addr + "/24"), ("docker0", "02:42:ac:11:00:01", -1, false, "172.17.0.1/16"),
                         ("lo", "00:00:00:00:00:00", -1, false, "")],
                address: addr)
        }
        func data(_ b: Box, cpu: [Double], mem: Double, gpu: [Double]? = nil, rx: Double, tx: Double) -> RemoteMonitor.DemoData {
            var d = RemoteMonitor.DemoData()
            d.systemFrame = frame(b)
            d.rates = ["eth0": (rx, tx), "docker0": (rx * 0.1, tx * 0.08)]
            let rxw = wave(cpu.count, base: 0.5, amp: 0.3, phase: 1)
            d.history = cpu.enumerated().map { i, c in
                (cpu: c, memory: mem + 0.02 * sin(Double(i) / 6), gpu: gpu?[i], rx: rx * rxw[i] * 2, tx: tx * rxw[i] * 2)
            }
            d.latency = 0.012
            return d
        }

        var web = data(box("web-01", "10.20.0.11", cpus: 8, mem: 32, used: 0.41, load: "0.42 0.38 0.31"),
                       cpu: wave(48, base: 0.24, amp: 0.12), mem: 0.41, rx: 2_400_000, tx: 5_800_000)
        web.processes = """
        48211 deploy 12.4 3.1 1048576 00:02 node /srv/shop/dist/server.js
        1203 www-data 1.2 0.4 131072 41-07:12:03 nginx: worker process
        1202 www-data 0.9 0.4 129024 41-07:12:03 nginx: worker process
        902 root 0.3 0.2 65536 41-07:12:09 /usr/bin/containerd
        1188 root 0.6 1.1 368640 41-07:12:05 /usr/bin/dockerd -H fd://
        2210 999 2.1 4.2 1376256 12-03:44:10 redis-server *:6379
        51007 deploy 0.0 0.0 5120 00:31 -bash
        1 root 0.0 0.0 12288 41-07:12:11 /sbin/init
        """
        web.services = """
        @@systemd
        shop-api.service loaded active running Shop API (Node.js)
        nginx.service loaded active running A high performance web server and a reverse proxy server
        docker.service loaded active running Docker Application Container Engine
        ssh.service loaded active running OpenBSD Secure Shell server
        cron.service loaded active running Regular background program processing daemon
        shop-worker.service loaded failed failed Shop background jobs
        unattended-upgrades.service loaded active running Unattended Upgrades Shutdown
        """
        web.containers = """
        @@docker
        7f3a9c2e1b44\tredis:7-alpine\tshop-redis\tUp 12 days\trunning\t127.0.0.1:6379->6379/tcp
        a1b2c3d4e5f6\tgrafana/grafana:11.2.0\tgrafana\tUp 3 days\trunning\t0.0.0.0:3000->3000/tcp, [::]:3000->3000/tcp
        0c9d8e7f6a5b\tprom/prometheus:v2.54.1\tprometheus\tUp 3 days\trunning\t127.0.0.1:9090->9090/tcp
        5e6f7a8b9c0d\tshop/migrations:2.4.0\tshop-migrate\tExited (0) 2 hours ago\texited\t
        """
        web.listening = """
        tcp\t0.0.0.0:22\tsshd\t880
        tcp\t0.0.0.0:443\tnginx\t1201
        tcp\t0.0.0.0:80\tnginx\t1201
        tcp\t0.0.0.0:3000\tdocker-proxy\t3301
        tcp\t10.20.0.11:8080\tnode\t48211
        tcp\t127.0.0.1:6379\tdocker-proxy\t2201
        tcp\t127.0.0.1:9090\tdocker-proxy\t3302
        udp\t127.0.0.53:53\tsystemd-resolve\t611
        """
        web.connections = """
        @@who
        deploy pts/0 2026-10-23 09:12 (10.20.0.2)
        deploy pts/1 2026-10-23 08:47 (10.20.0.2)
        @@sshports
        cfg:22
        @@conn
        10.20.0.2 51522 10.20.0.11 22
        @@ss
        0 0 10.20.0.11:22 10.20.0.2:51522 users:(("sshd",pid=50990,fd=4))
        0 0 10.20.0.11:22 10.20.0.2:50211 users:(("sshd",pid=49012,fd=4))
        0 0 10.20.0.11:8080 10.20.0.12:41822 users:(("node",pid=48211,fd=31))
        0 0 10.20.0.11:443 192.0.2.77:61204 users:(("nginx",pid=1203,fd=12))
        """
        web.remoteSessions = """
        @@tmux
        deploy-main|\(Int(Date().timeIntervalSince1970) - 86_400 * 3)|0|2|\(Int(Date().timeIntervalSince1970) - 3_600)
        agents|\(Int(Date().timeIntervalSince1970) - 7_200)|0|2|\(Int(Date().timeIntervalSince1970) - 20)
        @@tmuxpanes
        deploy-main|0|logs|1|1|%1|/dev/pts/4|tail|/srv/shop
        deploy-main|1|shell|0|1|%2|/dev/pts/5|bash|/srv/shop/scripts
        agents|0|claude|1|1|%3|/dev/pts/6|claude|/srv/shop
        agents|1|codex|0|1|%4|/dev/pts/7|codex|/srv/shop/api
        @@fg
        4101 pts/4 S+ tail -f /var/log/shop/api.log
        4102 pts/5 Ss+ -bash
        4103 pts/6 Sl+ claude
        4104 pts/7 Sl+ codex
        @@agents
        4103|claude|json|{"name":"Speed up orders.list query","nameSource":"user","status":"busy"}
        4104|codex|title|Add retry to payment webhook
        """
        web.logs = """
        2026-10-23T09:14:02+0000 web-01 systemd[1]: Started shop-api.service - Shop API (Node.js).
        2026-10-23T09:14:02+0000 web-01 node[48211]: listening on :8080
        2026-10-23T09:14:09+0000 web-01 node[48211]: slow query orders.list 412ms
        2026-10-23T09:15:00+0000 web-01 CRON[51210]: (deploy) CMD (/srv/shop/scripts/backup-db.sh)
        2026-10-23T09:16:41+0000 web-01 sshd[50990]: Accepted publickey for deploy from 10.20.0.2 port 51522 ssh2: ED25519 SHA256:demo
        """

        var gpuBox = box("gpu-01", "198.51.100.40", cpus: 64, mem: 512, used: 0.58, load: "18.20 17.95 17.40")
        gpuBox.hardware = "NVIDIA DGX Station"
        gpuBox.nvidia = (0..<4).map { i in "\(i), NVIDIA H100 80GB HBM3, \(88 + i * 3), \(61_000 + i * 2_400), 81559, \(64 + i * 2), \(540 + i * 22), 700" }
        var gpu = data(gpuBox, cpu: wave(48, base: 0.55, amp: 0.15), mem: 0.58,
                       gpu: wave(48, base: 0.88, amp: 0.08), rx: 48_000_000, tx: 12_000_000)
        gpu.processes = """
        77120 ml 798.0 9.8 52428800 07:13:51 python train.py --config configs/llm-ft.yaml
        77180 ml 41.0 0.6 3145728 07:13:40 python -m torch.distributed.run --nproc_per_node 4
        77302 ml 2.3 0.1 524288 05:02:11 tensorboard --logdir runs --port 6006
        1 root 0.0 0.0 12288 41-07:12:11 /sbin/init
        """
        gpu.gpuProcesses = (0..<4).map { "GPU-\($0), \(77_120 + $0), python, \(60_000 + $0 * 2_400)" }.joined(separator: "\n")
        gpu.remoteSessions = "@@tmux\ntraining|\(Int(Date().timeIntervalSince1970) - 30_000)|1|1|\(Int(Date().timeIntervalSince1970) - 30)\n"
            + "@@tmuxpanes\ntraining|0|train|1|1|%1|/dev/pts/2|python|/srv/ml\n"
            + "@@fg\n7711 pts/2 Rl+ python train.py --config configs/llm-ft.yaml\n"

        var db = data(box("db-primary", "10.20.0.21", cpus: 16, mem: 128, used: 0.71, load: "1.84 1.62 1.40"),
                      cpu: wave(48, base: 0.32, amp: 0.1, phase: 2), mem: 0.71, rx: 9_000_000, tx: 14_000_000)
        db.processes = """
        1420 postgres 18.2 22.4 30408704 41-07:11:58 /usr/lib/postgresql/16/bin/postgres -D /var/lib/postgresql/16/main
        88231 postgres 9.6 1.2 1622016 00:14:02 postgres: shop shop 10.20.0.11(41822) SELECT
        88240 postgres 6.1 1.1 1503232 00:13:40 postgres: shop shop 10.20.0.12(50210) idle in transaction
        1433 postgres 1.4 0.4 524288 41-07:11:55 postgres: checkpointer
        1434 postgres 0.9 0.3 393216 41-07:11:55 postgres: background writer
        1436 postgres 0.6 0.2 262144 41-07:11:55 postgres: walwriter
        1437 postgres 0.2 0.1 131072 41-07:11:55 postgres: autovacuum launcher
        2210 prometheus 0.8 0.3 409600 12-03:44:10 /usr/bin/prometheus-postgres-exporter
        903 root 0.1 0.1 65536 41-07:12:09 /usr/sbin/sshd -D
        1 root 0.0 0.0 12288 41-07:12:11 /sbin/init
        """
        let web2 = data(box("web-02", "10.20.0.12", cpus: 8, mem: 32, used: 0.37, load: "0.31 0.29 0.27"),
                        cpu: wave(48, base: 0.18, amp: 0.09, phase: 3), mem: 0.37, rx: 1_900_000, tx: 4_200_000)
        let bastion = data(box("bastion", "203.0.113.10", cpus: 2, mem: 4, used: 0.22, load: "0.02 0.03 0.01"),
                           cpu: wave(48, base: 0.03, amp: 0.02), mem: 0.22, rx: 300_000, tx: 280_000)
        let staging = data(box("staging", "192.0.2.50", cpus: 4, mem: 16, used: 0.33, load: "0.12 0.10 0.08"),
                           cpu: wave(48, base: 0.08, amp: 0.05, phase: 4), mem: 0.33, rx: 200_000, tx: 120_000)
        return ["web-01": web, "gpu-01": gpu, "db-primary": db, "web-02": web2, "bastion": bastion, "staging": staging]
    }
}
#endif
