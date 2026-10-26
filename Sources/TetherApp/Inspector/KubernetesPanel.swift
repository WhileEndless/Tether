import SwiftUI
import MonitorKit

/// Pods and nodes of the cluster the host's own `kubectl` reaches: status at a glance, logs,
/// describe, and deleting a pod (its controller starts a fresh one).
struct KubernetesPanel: View {
    let monitor: RemoteMonitor
    @State private var namespace = ""          // "" = all
    @State private var search = ""
    @State private var showNodes = false
    @State private var output: (title: String, text: String)?
    @State private var deleting: KubePod?
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            switch monitor.kubernetes {
            case .success(let cluster)?: clusterView(cluster)
            case .failure(let error)?:
                header(title: "Kubernetes", detail: "not reachable", warn: true)
                StateNote(symbol: "exclamationmark.triangle", title: "Kubernetes Not Reachable",
                          message: error.message.isEmpty ? "kubectl could not list pods." : error.message)
            case nil:
                header(title: "Kubernetes", detail: monitor.kubernetesLoaded ? "no client" : "checking…", warn: false)
                if monitor.kubernetesLoaded {
                    StateNote(symbol: "circle.hexagongrid", title: "No Kubernetes",
                              message: "No Kubernetes client (kubectl, k3s, microk8s or oc) was found on this host.")
                } else {
                    ProgressView().controlSize(.small).padding(.top, 24)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await monitor.refreshKubernetes() }
        .sheet(isPresented: Binding(get: { output != nil }, set: { if !$0 { output = nil } })) {
            LogSheet(title: output?.title ?? "", text: output?.text ?? "")
        }
        .confirmationDialog("Delete pod \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Pod", role: .destructive) { if let pod = deleting { run("delete", pod) } }
        } message: {
            Text("If a deployment or another controller owns it, a new pod replaces it (a restart). A pod on its own is gone for good.")
        }
    }

    /// The panel's top row while there is no cluster to show: what it is, and refresh.
    private func header(title: String, detail: String, warn: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.hexagongrid").foregroundStyle(.secondary)
            Text(title).fontWeight(.medium)
            Text(detail).font(.caption).foregroundStyle(warn ? .orange : .secondary)
            Spacer()
            Button { Task { await monitor.refreshKubernetes() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Check again")
        }
        .padding(10)
    }

    /// A message under the header, at the top (an error can be several lines of kubectl output).
    private struct StateNote: View {
        let symbol: String
        let title: String
        let message: String
        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol).font(.headline)
                Text(message)
                    .font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.top, 8)
        }
    }

    private func clusterView(_ cluster: KubeCluster) -> some View {
        let pods = cluster.pods.filter { p in
            (namespace.isEmpty || p.namespace == namespace)
                && (search.isEmpty || p.name.localizedCaseInsensitiveContains(search) || p.namespace.localizedCaseInsensitiveContains(search))
        }
        let failing = cluster.pods.filter { $0.health == .failing }.count
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "circle.hexagongrid").foregroundStyle(.secondary)
                Text(cluster.context.isEmpty ? cluster.tool : cluster.context).fontWeight(.medium).lineLimit(1)
                Text("\(cluster.pods.count) pods\(failing > 0 ? " · \(failing) failing" : "")")
                    .font(.caption).foregroundStyle(failing > 0 ? .orange : .secondary)
                Spacer()
                Button { Task { await monitor.refreshKubernetes() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
                Button {
                    ExportPanel.save(title: "Export Pods", baseName: "pods", formats: MonitorExport.Format.table) { MonitorExport.pods(pods, format: $0) }
                } label: { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.borderless)
                    .disabled(pods.isEmpty)
                    .help("Export the pods shown as CSV")
            }
            .padding(.horizontal, 10).padding(.top, 10)
            HStack(spacing: 8) {
                Picker("Namespace", selection: $namespace) {
                    Text("All namespaces").tag("")
                    ForEach(cluster.namespaces, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                TextField("Filter pods", text: $search).textFieldStyle(.roundedBorder)
            }
            .padding(10)
            if let message {
                Text(message).font(.caption).foregroundStyle(.red).padding(.horizontal, 10).padding(.bottom, 6)
            }
            List {
                if !cluster.nodes.isEmpty {
                    DisclosureGroup(isExpanded: $showNodes) {
                        ForEach(cluster.nodes) { node in
                            HStack {
                                Circle().fill(node.ready ? Color.green : .red).frame(width: 7, height: 7)
                                Text(node.name).lineLimit(1)
                                Spacer()
                                Text(node.version).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    } label: {
                        let notReady = cluster.nodes.filter { !$0.ready }.count
                        Text("Nodes (\(cluster.nodes.count)\(notReady > 0 ? ", \(notReady) not ready" : ""))")
                            .foregroundStyle(notReady > 0 ? .orange : .primary)
                    }
                }
                ForEach(pods) { pod in row(pod) }
            }
            .overlay {
                if pods.isEmpty {
                    EmptyStateView(symbol: "circle.hexagongrid", title: "No Pods",
                                   message: search.isEmpty && namespace.isEmpty ? "The cluster has no pods." : "No pods match.")
                }
            }
        }
    }

    private func row(_ pod: KubePod) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(pod.health == .ok ? Color.green : pod.health == .failing ? .red : .orange)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(pod.name).lineLimit(1)
                Text([pod.namespace, pod.node, pod.created.map { $0.formatted(.relative(presentation: .named)) } ?? ""]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(pod.status).font(.caption).foregroundStyle(pod.health == .failing ? .red : .secondary).lineLimit(1)
                Text("\(pod.readyCount)/\(pod.containers.count)\(pod.restarts > 0 ? " · \(pod.restarts) restarts" : "")")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(pod.restarts > 0 ? .orange : .secondary)
            }
            Menu {
                Button("Show Logs") { run("logs", pod) }
                Button("Describe") { run("describe", pod) }
                Divider()
                Button("Delete Pod…", role: .destructive) { deleting = pod }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .help("\(pod.namespace)/\(pod.name) — \(pod.status)")
    }

    private func run(_ action: String, _ pod: KubePod) {
        Task {
            let r = await monitor.kubernetes(action, pod)
            if action == "delete" {
                withAnimation { message = r.ok ? nil : r.output.trimmingCharacters(in: .whitespacesAndNewlines) }
            } else {
                output = ("\(pod.name) — \(action == "logs" ? "Logs" : "Describe")", r.output)
            }
        }
    }
}
