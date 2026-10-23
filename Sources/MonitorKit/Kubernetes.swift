import Foundation

/// Kubernetes as seen from a host: whatever `kubectl` (or `k3s kubectl`, `microk8s kubectl`, `oc`)
/// on that host can reach with its own configuration. Nothing is installed; read-only listing,
/// plus logs, describe and deleting a pod (its controller starts a new one).
public struct KubeCluster: Equatable, Sendable {
    /// The command used on the host, e.g. "kubectl" or "k3s kubectl" (one of `KubeScripts.tools`).
    public var tool: String
    public var context: String
    public var pods: [KubePod]
    public var nodes: [KubeNode]

    public var namespaces: [String] { Array(Set(pods.map(\.namespace))).sorted() }
}

public struct KubePod: Identifiable, Hashable, Sendable {
    public struct Container: Hashable, Sendable {
        public var ready: Bool
        public var restarts: Int
        /// Why it is waiting or why it stopped (CrashLoopBackOff, ImagePullBackOff, Completed, …).
        public var reason: String
    }

    public enum Health: Int, Comparable, Sendable {
        case failing, starting, ok
        public static func < (a: Health, b: Health) -> Bool { a.rawValue < b.rawValue }
    }

    public var namespace: String
    public var name: String
    public var phase: String
    public var node: String
    public var created: Date?
    public var terminating: Bool
    public var containers: [Container]

    public var id: String { namespace + "/" + name }
    public var readyCount: Int { containers.filter(\.ready).count }
    public var restarts: Int { containers.reduce(0) { $0 + $1.restarts } }

    /// What `kubectl get pods` shows in STATUS.
    public var status: String {
        if terminating { return "Terminating" }
        if let reason = containers.first(where: { !$0.reason.isEmpty && !$0.ready })?.reason { return reason }
        return phase
    }

    public var health: Health {
        let s = status
        if s == "Succeeded" || s == "Completed" { return .ok }
        if s == "Failed" || s == "Error" || s == "Unknown" || s.hasSuffix("BackOff") || s.hasPrefix("Err")
            || s == "OOMKilled" || s.hasPrefix("Invalid") || s.hasPrefix("CreateContainer") { return .failing }
        if phase == "Running" && !terminating && readyCount == containers.count { return .ok }
        return .starting
    }
}

public struct KubeNode: Identifiable, Hashable, Sendable {
    public var name: String
    public var ready: Bool
    public var version: String
    public var id: String { name }
}

public enum KubeScripts {
    /// Commands accepted as the Kubernetes client (anything else reported by a host is ignored).
    public static let tools = ["kubectl", "k3s kubectl", "microk8s kubectl", "oc"]

    static let podPath = #"{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.spec.nodeName}{"\t"}{.metadata.creationTimestamp}{"\t"}{.metadata.deletionTimestamp}{"\t"}{range .status.containerStatuses[*]}{.ready}{","}{.restartCount}{","}{.state.waiting.reason}{.state.terminated.reason}{";"}{end}{"\n"}{end}"#
    static let nodePath = #"{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\t"}{.status.nodeInfo.kubeletVersion}{"\n"}{end}"#

    /// Lists pods and nodes. Sections: @@k8s-tool, @@k8s-context, @@k8s-pods, @@k8s-nodes, or
    /// @@k8s-error with what kubectl said (e.g. no cluster configured).
    public static let list = """
    export LC_ALL=C
    K=""
    for c in kubectl "k3s kubectl" "microk8s kubectl" oc; do
      set -- $c; command -v "$1" >/dev/null 2>&1 && { K="$c"; break; }
    done
    [ -n "$K" ] || exit 0
    P='\(podPath)'
    N='\(nodePath)'
    run() { $K --request-timeout=8s "$@" 2>/dev/null || sudo -n $K --request-timeout=8s "$@" 2>/dev/null; }
    if ! pods=$(run get pods -A -o jsonpath="$P"); then
      echo "@@k8s-error"; $K --request-timeout=8s get pods -A 2>&1 | head -n 3; exit 0
    fi
    echo "@@k8s-tool"; echo "$K"
    echo "@@k8s-context"; run config current-context
    echo "@@k8s-pods"; printf '%s\\n' "$pods"
    echo "@@k8s-nodes"; run get nodes -o jsonpath="$N"
    true
    """

    /// `$1` = tool, `$2` = logs|describe|delete, `$3` = namespace, `$4` = pod.
    public static let action = #"""
K=$1; A=$2; NS=$3; P=$4
case "$A" in
  logs) set -- logs -n "$NS" "$P" --all-containers --prefix --tail 300 ;;
  describe) set -- describe pod -n "$NS" "$P" ;;
  delete) set -- delete pod -n "$NS" "$P" --wait=false ;;
  *) echo "unknown action"; exit 2 ;;
esac
$K --request-timeout=20s "$@" 2>&1 || sudo -n $K --request-timeout=20s "$@" 2>&1
"""#

    /// Windows: kubectl's JSON, read by the parser (PowerShell would mangle the jsonpath quotes).
    public static let listWindows = #"""
$k = @('kubectl', 'oc') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
if (-not $k) { return }
$pods = & $k --request-timeout=8s get pods -A -o json 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { '@@k8s-error'; ($pods -split "`n" | Select-Object -First 3); return }
'@@k8s-tool'; $k
'@@k8s-context'; & $k config current-context 2>$null
'@@k8s-pods-json'; ($pods -replace "`r?`n", ' ')
'@@k8s-nodes-json'; ((& $k --request-timeout=8s get nodes -o json 2>$null | Out-String) -replace "`r?`n", ' ')
"""#

    /// `$A[0]` = tool, `$A[1]` = logs|describe|delete, `$A[2]` = namespace, `$A[3]` = pod.
    public static let actionWindows = #"""
switch ($A[1]) {
  'logs' { & $A[0] --request-timeout=20s logs -n $A[2] $A[3] --all-containers --prefix --tail 300 2>&1 }
  'describe' { & $A[0] --request-timeout=20s describe pod -n $A[2] $A[3] 2>&1 }
  'delete' { & $A[0] --request-timeout=20s delete pod -n $A[2] $A[3] --wait=false 2>&1 }
}
"""#
}

extension ProbeParser {
    /// nil when the host has no Kubernetes client; `.failure` with kubectl's message when it has one
    /// but cannot list pods (no cluster configured, no permission, …).
    public static func kubernetes(_ text: String) -> Result<KubeCluster, KubeError>? {
        let s = sections(text)
        if let error = s["k8s-error"] {
            return .failure(KubeError(message: error.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        guard let tool = s["k8s-tool"]?.first?.trimmingCharacters(in: .whitespaces), KubeScripts.tools.contains(tool) else { return nil }
        let context = s["k8s-context"]?.first?.trimmingCharacters(in: .whitespaces) ?? ""
        var pods: [KubePod] = []
        var nodes: [KubeNode] = []
        if let lines = s["k8s-pods"] { pods = lines.compactMap(pod) }
        if let lines = s["k8s-nodes"] { nodes = lines.compactMap(node) }
        if let json = s["k8s-pods-json"]?.joined() { pods = podsFromJSON(json) }
        if let json = s["k8s-nodes-json"]?.joined() { nodes = nodesFromJSON(json) }
        pods.sort { ($0.health, $0.namespace, $0.name) < ($1.health, $1.namespace, $1.name) }
        return .success(KubeCluster(tool: tool, context: context, pods: pods, nodes: nodes.sorted { $0.name < $1.name }))
    }

    private static let iso = ISO8601DateFormatter()

    private static func pod(_ line: String) -> KubePod? {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 6, !f[1].isEmpty else { return nil }
        let containers = (f.count > 6 ? f[6] : "").split(separator: ";").compactMap { c -> KubePod.Container? in
            let p = c.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 2 else { return nil }
            return KubePod.Container(ready: p[0] == "true", restarts: Int(p[1]) ?? 0, reason: p.count > 2 ? p[2] : "")
        }
        return KubePod(namespace: f[0], name: f[1], phase: f[2], node: f[3], created: iso.date(from: f[4]),
                       terminating: !f[5].isEmpty, containers: containers)
    }

    private static func node(_ line: String) -> KubeNode? {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 2, !f[0].isEmpty else { return nil }
        return KubeNode(name: f[0], ready: f[1] == "True", version: f.count > 2 ? f[2] : "")
    }

    private static func items(_ json: String) -> [[String: Any]] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return obj["items"] as? [[String: Any]] ?? []
    }

    private static func podsFromJSON(_ json: String) -> [KubePod] {
        items(json).compactMap { item in
            let meta = item["metadata"] as? [String: Any] ?? [:]
            let spec = item["spec"] as? [String: Any] ?? [:]
            let status = item["status"] as? [String: Any] ?? [:]
            guard let name = meta["name"] as? String else { return nil }
            let containers = (status["containerStatuses"] as? [[String: Any]] ?? []).map { c -> KubePod.Container in
                let state = c["state"] as? [String: Any] ?? [:]
                let reason = ((state["waiting"] as? [String: Any])?["reason"] as? String)
                    ?? ((state["terminated"] as? [String: Any])?["reason"] as? String) ?? ""
                return KubePod.Container(ready: c["ready"] as? Bool ?? false, restarts: c["restartCount"] as? Int ?? 0, reason: reason)
            }
            return KubePod(namespace: meta["namespace"] as? String ?? "", name: name, phase: status["phase"] as? String ?? "",
                           node: spec["nodeName"] as? String ?? "", created: (meta["creationTimestamp"] as? String).flatMap(iso.date(from:)),
                           terminating: meta["deletionTimestamp"] != nil, containers: containers)
        }
    }

    private static func nodesFromJSON(_ json: String) -> [KubeNode] {
        items(json).compactMap { item in
            guard let name = (item["metadata"] as? [String: Any])?["name"] as? String else { return nil }
            let status = item["status"] as? [String: Any] ?? [:]
            let ready = (status["conditions"] as? [[String: Any]] ?? []).first { $0["type"] as? String == "Ready" }?["status"] as? String
            let version = (status["nodeInfo"] as? [String: Any])?["kubeletVersion"] as? String ?? ""
            return KubeNode(name: name, ready: ready == "True", version: version)
        }
    }
}

public struct KubeError: Error, Equatable, Sendable {
    public var message: String
}
