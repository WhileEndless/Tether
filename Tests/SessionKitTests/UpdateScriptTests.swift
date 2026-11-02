import Foundation
import Testing
import TestSupport
import TetherCore

/// Updating from source: a release is fetched and built in a work folder, then installed with
/// `make install` once Tether has ended. Run here with stand-ins for curl, make, swift and open
/// (nothing is downloaded, nothing outside a temporary folder is touched).
@Suite struct UpdateScriptTests {
    struct Sandbox {
        let root: URL
        var bin: URL { root.appendingPathComponent("bin") }
        var work: URL { root.appendingPathComponent("tether-update-work") }
        var apps: URL { root.appendingPathComponent("Applications") }
        var opened: URL { root.appendingPathComponent("opened") }
        var cache: URL { root.appendingPathComponent("Caches/tether-update-build") }

        /// A release whose Makefile builds an app of `version`.
        init(version: String) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("tether-update-test-\(UUID().uuidString.prefix(8))")
            let fm = FileManager.default
            try fm.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try fm.createDirectory(at: root.appendingPathComponent("Applications"), withIntermediateDirectories: true)
            let release = root.appendingPathComponent("release/tether-\(version)")
            try fm.createDirectory(at: release, withIntermediateDirectories: true)
            try "VERSION=\(version)\n".write(to: release.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
            func tool(_ name: String, _ body: String) throws {
                let url = root.appendingPathComponent("bin/\(name)")
                try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            // curl … URL -o FILE: the release's source as GitHub serves it (one top folder).
            try tool("curl", """
            out=; while [ $# -gt 0 ]; do [ "$1" = -o ] && { out=$2; shift; }; shift; done
            tar -czf "$out" -C "\(root.path)/release" "tether-\(version)"
            """)
            try tool("swift", "exit 0\n")
            // make app: an app with the version in VERSION; make install: copied to INSTALL_DIR.
            try tool("make", """
            v=$(sed -n 's/^VERSION=//p' VERSION)
            case $1 in
            app) [ -f .build/fail-once ] && { rm -f .build/fail-once; echo "error: stale build" >&2; exit 1; }
                 mkdir -p .build dist/Tether.app/Contents; echo "$v" >> .build/builds
                 printf '<plist><dict><key>CFBundleShortVersionString</key>\\n<string>%s</string></dict></plist>\\n' "$v" > dist/Tether.app/Contents/Info.plist ;;
            install-built) dest=${2#INSTALL_DIR=}; rm -rf "$dest/Tether.app"; cp -R dist/Tether.app "$dest/Tether.app" ;;
            esac
            """)
            try tool("open", "echo \"$1\" > \"\(root.path)/opened\"\n")
        }

        func run(_ script: String, _ args: [String]) -> BoundedProcess.Result {
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = bin.path + ":/usr/bin:/bin"
            env["TETHER_UPDATE_SKIP_TOOLS_CHECK"] = "1"
            env["TMUX"] = nil
            return BoundedProcess.run("/bin/sh", ["-c", script, "test"] + args, environment: env, timeout: 30)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func aReleaseIsFetchedBuiltAndInstalledAfterTetherEnds() throws {
        let box = try Sandbox(version: "1.2.3")
        defer { box.remove() }
        let built = box.run(UpdateScripts.fetchAndBuild, ["v1.2.3", box.work.path, "https://github.com/example/tether", "1.2.3"])
        #expect(built.status == 0, "\(built.errorOutput)")
        #expect(built.output.contains("Built "))
        #expect(FileManager.default.fileExists(atPath: box.work.appendingPathComponent("src/dist/Tether.app").path))
        #expect(!FileManager.default.fileExists(atPath: box.work.appendingPathComponent("source.tar.gz").path))

        // A process that already ended stands for the Tether that quit.
        let gone = BoundedProcess.run("/bin/sh", ["-c", "echo $$"], timeout: 5).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let log = box.root.appendingPathComponent("install.log")
        let installed = box.run(UpdateScripts.install, [gone, box.work.appendingPathComponent("src").path, box.apps.path, "1",
                                                        box.work.path, log.path])
        #expect(installed.status == 0, "\((try? String(contentsOf: log, encoding: .utf8)) ?? "")")
        let plist = try String(contentsOf: box.apps.appendingPathComponent("Tether.app/Contents/Info.plist"), encoding: .utf8)
        #expect(plist.contains("<string>1.2.3</string>"))
        #expect(!FileManager.default.fileExists(atPath: box.work.path), "the work folder is removed")
        #expect((try? String(contentsOf: box.opened, encoding: .utf8))?.contains("Applications/Tether.app") == true, "opened again")
    }

    /// A tag that is not the version expected (or a build of another version) installs nothing.
    @Test func aBuildOfAnotherVersionIsRefused() throws {
        let box = try Sandbox(version: "1.2.3")
        defer { box.remove() }
        let r = box.run(UpdateScripts.fetchAndBuild, ["v1.2.3", box.work.path, "https://github.com/example/tether", "9.9.9"])
        #expect(r.status == 4)
        #expect(r.errorOutput.contains("not 9.9.9"))
    }

    @Test func onlyGitHubAndPlainTags() throws {
        let box = try Sandbox(version: "1.2.3")
        defer { box.remove() }
        #expect(box.run(UpdateScripts.fetchAndBuild, ["v1.2.3", box.work.path, "https://example.com/tether", "1.2.3"]).status == 2)
        #expect(box.run(UpdateScripts.fetchAndBuild, ["v1;rm", box.work.path, "https://github.com/example/tether", "1.2.3"]).status == 2)
    }

    /// While the Tether being replaced still runs, nothing is installed (here: it never ends, and
    /// the installer gives up — shortened by stopping the test's wait).
    @Test func nothingIsInstalledWhileTetherRuns() throws {
        let box = try Sandbox(version: "1.2.3")
        defer { box.remove() }
        _ = box.run(UpdateScripts.fetchAndBuild, ["v1.2.3", box.work.path, "https://github.com/example/tether", "1.2.3"])
        let me = String(ProcessInfo.processInfo.processIdentifier)
        let r = BoundedProcess.run("/bin/sh", ["-c", UpdateScripts.install, "test", me, box.work.appendingPathComponent("src").path,
                                              box.apps.path, "0", box.work.path, box.root.appendingPathComponent("log").path],
                                   environment: ["PATH": box.bin.path + ":/usr/bin:/bin"], timeout: 2)
        #expect(r.timedOut)
        #expect(!FileManager.default.fileExists(atPath: box.apps.appendingPathComponent("Tether.app").path))
    }

    /// Tether downloads the source itself (to show its progress) and hands it over.
    @Test func aSourceDownloadedBeforeIsUsed() throws {
        let box = try Sandbox(version: "2.0.0")
        defer { box.remove() }
        try FileManager.default.createDirectory(at: box.work, withIntermediateDirectories: true)
        let tarball = box.work.appendingPathComponent("given.tar.gz")
        let made = BoundedProcess.run("/bin/sh", ["-c", "tar -czf \"$1\" -C \"$2\" tether-2.0.0", "x", tarball.path,
                                                  box.root.appendingPathComponent("release").path], timeout: 10)
        #expect(made.status == 0)
        // curl would fail: it must not be asked.
        try "#!/bin/sh\nexit 7\n".write(to: box.bin.appendingPathComponent("curl"), atomically: true, encoding: .utf8)
        let r = box.run(UpdateScripts.fetchAndBuild, ["v2.0.0", box.work.path, "https://github.com/example/tether", "2.0.0", tarball.path])
        #expect(r.status == 0, "\(r.errorOutput)")
        #expect(!r.output.contains("Downloading"))
        #expect(!FileManager.default.fileExists(atPath: tarball.path), "the download is removed once unpacked")
    }

    /// With a build folder kept between updates, the next release reuses what the one before
    /// compiled: unchanged files keep their identity (SwiftPM compiles them not again), changed ones
    /// are replaced, removed ones go, and the app is still installed from next to the source.
    @Test func theNextUpdateReusesTheBuildFolder() throws {
        let box = try Sandbox(version: "1.2.3")
        defer { box.remove() }
        let fm = FileManager.default
        let release = box.root.appendingPathComponent("release/tether-1.2.3")
        try "same\n".write(to: release.appendingPathComponent("Same.swift"), atomically: true, encoding: .utf8)
        try "old\n".write(to: release.appendingPathComponent("Gone.swift"), atomically: true, encoding: .utf8)
        let repo = "https://github.com/example/tether"
        let first = box.run(UpdateScripts.fetchAndBuild, ["v1.2.3", box.work.path, repo, "1.2.3", "", box.cache.path])
        #expect(first.status == 0, "\(first.errorOutput)")
        #expect(fm.fileExists(atPath: box.work.appendingPathComponent("src/dist/Tether.app").path))
        let src = box.cache.appendingPathComponent("src")
        func inode(_ name: String) throws -> Int? {
            try fm.attributesOfItem(atPath: src.appendingPathComponent(name).path)[.systemFileNumber] as? Int
        }
        let sameBefore = try inode("Same.swift")

        // The next release: VERSION changed, Gone.swift removed; the work folder starts empty again.
        try fm.removeItem(at: box.work)
        try "VERSION=1.2.4\n".write(to: release.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        try fm.removeItem(at: release.appendingPathComponent("Gone.swift"))
        let second = box.run(UpdateScripts.fetchAndBuild, ["v1.2.4", box.work.path, repo, "1.2.4", "", box.cache.path])
        #expect(second.status == 0, "\(second.errorOutput)")
        #expect(try inode("Same.swift") == sameBefore, "an unchanged file is left alone")
        #expect(!fm.fileExists(atPath: src.appendingPathComponent("Gone.swift").path))
        #expect(try String(contentsOf: src.appendingPathComponent(".build/builds"), encoding: .utf8) == "1.2.3\n1.2.4\n",
                "the build folder was kept")
        #expect(!fm.fileExists(atPath: src.appendingPathComponent("dist/Tether.app").path), "moved next to the source")

        let gone = BoundedProcess.run("/bin/sh", ["-c", "echo $$"], timeout: 5).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let log = box.root.appendingPathComponent("install.log")
        let installed = box.run(UpdateScripts.install, [gone, box.work.appendingPathComponent("src").path, box.apps.path, "0",
                                                        box.work.path, log.path])
        #expect(installed.status == 0, "\((try? String(contentsOf: log, encoding: .utf8)) ?? "")")
        let plist = try String(contentsOf: box.apps.appendingPathComponent("Tether.app/Contents/Info.plist"), encoding: .utf8)
        #expect(plist.contains("<string>1.2.4</string>"))
    }

    /// A build folder that no longer builds (another Xcode, damaged) is built once more from clean.
    @Test func aFailedBuildIsTriedOnceMoreFromACleanFolder() throws {
        let box = try Sandbox(version: "1.2.3")
        defer { box.remove() }
        let build = box.cache.appendingPathComponent("src/.build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try "".write(to: build.appendingPathComponent("fail-once"), atomically: true, encoding: .utf8)
        try "old\n".write(to: build.appendingPathComponent("stale"), atomically: true, encoding: .utf8)
        let r = box.run(UpdateScripts.fetchAndBuild, ["v1.2.3", box.work.path, "https://github.com/example/tether", "1.2.3", "",
                                                      box.cache.path])
        #expect(r.status == 0, "\(r.errorOutput)")
        #expect(r.output.contains("again from a clean folder"))
        #expect(!FileManager.default.fileExists(atPath: build.appendingPathComponent("stale").path))
        #expect(FileManager.default.fileExists(atPath: box.work.appendingPathComponent("src/dist/Tether.app").path))
    }

    /// Without a cache a failed build is not tried again, and only a folder of the expected name is used.
    @Test func theBuildFolderIsChecked() throws {
        let box = try Sandbox(version: "1.2.3")
        defer { box.remove() }
        let repo = "https://github.com/example/tether"
        #expect(box.run(UpdateScripts.fetchAndBuild, ["v1.2.3", box.work.path, repo, "1.2.3", "", box.root.path]).status == 2)
        #expect(box.run(UpdateScripts.fetchAndBuild, ["v1.2.3", box.work.path, repo, "1.2.3", "", "tether-update-build"]).status == 2)
        #expect(!FileManager.default.fileExists(atPath: box.work.appendingPathComponent("src").path), "nothing unpacked")
    }

    /// The build's progress comes from SwiftPM's steps and never goes back (the helper's own,
    /// shorter build comes after the app's).
    @Test func buildProgressIsReadFromTheLog() {
        var p = UpdateBuildProgress()
        #expect(p.progress == nil)
        p.read("Unpacking v1.2.3\nBuilding v1.2.3\nBuilding for production...\n[1/200] Compiling Tether A.swift\n")
        #expect(p.step == "Compiling…")
        #expect(abs((p.progress ?? 0) - 0.0045) < 0.001)
        p.read("[100/200] Compiling Tether B.swift\n[200/2")      // a line cut in two
        #expect(abs((p.progress ?? 0) - 0.45) < 0.001)
        p.read("00] Linking Tether\nBuild of product 'Tether' complete! (90.1s)\n[1/5] Compiling askpass\n")
        #expect(p.progress == 0.9, "the helper's [1/5] does not take it back")
        p.read("Building v1.2.3 again from a clean folder\n")
        #expect(p.progress == 0.9, "a second try does not take it back")
        p.read("Built /tmp/x/src/dist/Tether.app\n")
        #expect(p.progress == 1)
    }
}
