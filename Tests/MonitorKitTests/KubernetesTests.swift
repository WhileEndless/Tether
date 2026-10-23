import Foundation
import Testing
@testable import MonitorKit

@Suite struct KubernetesTests {
    /// Runs a script with a fake `kubectl` first in PATH that answers like a small cluster.
    func run(_ script: String, _ args: [String] = [], kubectl: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-k8s-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("kubectl")
        try kubectl.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh"] + args
        p.environment = ["PATH": dir.path + ":/usr/bin:/bin"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    static let cluster = #"""
#!/bin/sh
case "$*" in
  *"config current-context"*) echo "prod-eu" ;;
  *"get pods"*) printf 'default\tweb-7d4\tRunning\tnode-1\t2026-10-20T10:00:00Z\t\ttrue,0,;true,1,;\n'
                printf 'jobs\tbackup-29\tRunning\tnode-2\t2026-10-24T09:00:00Z\t\tfalse,7,CrashLoopBackOff;\n'
                printf 'jobs\tdone-1\tSucceeded\tnode-2\t2026-10-24T08:00:00Z\t\tfalse,0,Completed;\n' ;;
  *"get nodes"*) printf 'node-1\tTrue\tv1.31.2\nnode-2\tFalse\tv1.31.2\n' ;;
  *"logs"*) echo "LOGS $*" ;;
esac
"""#

    @Test func listsPodsAndNodesThroughKubectl() throws {
        let out = try run(KubeScripts.list, kubectl: Self.cluster)
        guard case .success(let c)? = ProbeParser.kubernetes(out) else { Issue.record("output: \(out)"); return }
        #expect(c.tool == "kubectl" && c.context == "prod-eu")
        // Failing pods first, then by namespace and name.
        #expect(c.pods.map(\.name) == ["backup-29", "web-7d4", "done-1"])
        let backup = try #require(c.pods.first { $0.name == "backup-29" })
        #expect(backup.status == "CrashLoopBackOff" && backup.health == .failing && backup.restarts == 7)
        let web = try #require(c.pods.first { $0.name == "web-7d4" })
        #expect(web.health == .ok && web.readyCount == 2 && web.restarts == 1)
        #expect(c.pods.first { $0.name == "done-1" }?.health == .ok)
        #expect(c.nodes.map(\.ready) == [true, false])
        #expect(c.namespaces == ["default", "jobs"])
    }

    @Test func reportsWhyItCannotList() throws {
        let out = try run(KubeScripts.list, kubectl: "#!/bin/sh\necho 'The connection to the server localhost:8080 was refused' >&2\nexit 1\n")
        guard case .failure(let e)? = ProbeParser.kubernetes(out) else { Issue.record("output: \(out)"); return }
        #expect(e.message.contains("refused"))
    }

    @Test func noClientMeansNothing() {
        #expect(ProbeParser.kubernetes("") == nil)
        // A host cannot make Tether run something else as "the tool".
        #expect(ProbeParser.kubernetes("@@k8s-tool\nrm -rf /\n@@k8s-pods\n") == nil)
    }

    @Test func actionsPassArgumentsSafely() throws {
        let out = try run(KubeScripts.action, ["kubectl", "logs", "default", "web; echo pwned"], kubectl: Self.cluster)
        #expect(out.contains("LOGS") && out.contains("web; echo pwned") && !out.contains("\npwned"))
        #expect(try run(KubeScripts.action, ["kubectl", "exec", "default", "web"], kubectl: Self.cluster).contains("unknown action"))
    }

    @Test func windowsJSONParses() throws {
        let pods = #"{"items":[{"metadata":{"namespace":"default","name":"api","creationTimestamp":"2026-10-24T09:00:00Z"},"spec":{"nodeName":"n1"},"status":{"phase":"Pending","containerStatuses":[{"ready":false,"restartCount":0,"state":{"waiting":{"reason":"ImagePullBackOff"}}}]}}]}"#
        let nodes = #"{"items":[{"metadata":{"name":"n1"},"status":{"conditions":[{"type":"Ready","status":"True"}],"nodeInfo":{"kubeletVersion":"v1.30.0"}}}]}"#
        let text = "@@k8s-tool\nkubectl\n@@k8s-context\nlab\n@@k8s-pods-json\n\(pods)\n@@k8s-nodes-json\n\(nodes)\n"
        guard case .success(let c)? = ProbeParser.kubernetes(text) else { Issue.record("no cluster"); return }
        #expect(c.pods.first?.status == "ImagePullBackOff" && c.pods.first?.health == .failing)
        #expect(c.nodes.first?.ready == true && c.nodes.first?.version == "v1.30.0")
    }
}
