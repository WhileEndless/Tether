import SwiftUI
import TetherCore

/// A host's own feature switches (see `HostFeature`), as menu items: in the sidebar's host menu
/// and the host panel's menu. A host's choice comes before Settings ▸ Monitoring.
struct HostFeaturesMenu: View {
    @Environment(AppModel.self) private var model
    let target: ConnectionTarget
    /// Opens the full list (the host editor), when the host has one.
    var showAll: (() -> Void)?

    var body: some View {
        let monitoring = model.feature(.monitoring, for: target).on
        let device = model.isDevice(target)
        Toggle("Monitor This Host", isOn: Binding(get: { monitoring }, set: { model.setHostChoice(.monitoring, for: target, $0) }))
            .disabled(device)
        Toggle("Network Device or Limited Shell", isOn: Binding(get: { device }, set: {
            model.setShellAccess($0 ? .device : (model.metadata(for: target.key).detectedDevice == true ? .scripts : .automatic), for: target)
        }))
        .help("Cisco, Junos, FortiOS, RouterOS, a menu or git-shell: Tether only opens the device's own command line and runs nothing else there")
        Menu("Host Panel Tabs") {
            ForEach(HostFeature.panels) { f in
                Toggle(f.title, isOn: Binding(get: { model.isEnabled(f, for: target) },
                                              set: { model.setHostChoice(f, for: target, $0) }))
                    .disabled(f.needsMonitoring && !monitoring)
            }
        }
        Menu("In the Background") {
            ForEach(HostFeature.allCases.filter { $0.group != .panels && $0 != .monitoring }) { f in
                Toggle(f.title, isOn: Binding(get: { model.isEnabled(f, for: target) },
                                              set: { model.setHostChoice(f, for: target, $0) }))
                    .disabled(f.needsMonitoring && !monitoring)
            }
        }
        if model.metadata(for: target.key).features != nil {
            Button("Use Settings for This Host") {
                model.updateMetadata(for: target.key) { $0.features = nil }
                model.hostFeaturesChanged(target)
            }
        }
        if let showAll { Button("All Host Features…", action: showAll) }
    }
}

/// The host editor's list: every feature with System Setting / On / Off.
struct HostFeaturesSection: View {
    @Environment(AppModel.self) private var model
    let target: ConnectionTarget

    var body: some View {
        Section {
            Picker(selection: Binding(get: { model.shellAccess(for: target) }, set: { model.setShellAccess($0, for: target) })) {
                ForEach(ShellAccess.allCases) { Text($0.title).tag($0) }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Shell")
                    Text(model.detectedShell(for: target).map { "Detected: \($0)" } ?? "Detected on the first connection")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.isDevice(target) {
                Text("A network device or limited shell (Cisco, Junos, FortiOS, RouterOS, a menu, git-shell) gets a plain login: its own command line, exactly as `ssh` gives it. Tether runs nothing else there — no monitoring, file browsing, uploads, persistence or key setup; downloads use classic scp and port forwards use the connection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(HostFeature.Group.allCases, id: \.self) { group in
                DisclosureGroup(group.rawValue) {
                    ForEach(HostFeature.allCases.filter { $0.group == group }) { f in row(f) }
                }
            }
        } header: {
            Text("What Tether Runs for This Host")
        } footer: {
            Text("System Setting follows Settings ▸ Monitoring. With monitoring off for this host, nothing that reads its system runs, whatever the rows below say.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ f: HostFeature) -> some View {
        let system = model.settings.isEnabled(f)
        return Picker(selection: Binding(get: { model.hostChoice(f, for: target) },
                                         set: { model.setHostChoice(f, for: target, $0) })) {
            Text("System Setting (\(system ? "On" : "Off"))").tag(Bool?.none)
            Text("On").tag(Bool?.some(true))
            Text("Off").tag(Bool?.some(false))
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(f.title)
                Text(f.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Shown where monitoring would be, when it is off: says where, and turns it back on there.
struct MonitoringOffNote: View {
    @Environment(AppModel.self) private var model
    let target: ConnectionTarget

    var body: some View {
        let origin = model.feature(.monitoring, for: target).origin
        HStack(spacing: 8) {
            Image(systemName: origin == .unsupported ? "network" : "eye.slash").foregroundStyle(.secondary)
            Text(origin == .unsupported ? "A network device or limited shell: Tether runs nothing on it"
                 : origin == .host ? "Monitoring is off for this host" : "Monitoring is off in Settings")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            if origin == .unsupported {
                Button("It Has a Shell") { model.setShellAccess(.scripts, for: target) }
                    .controlSize(.small)
                    .help("Treat it as a normal host again (Linux, BSD, macOS, Windows)")
            } else {
                Button("Turn On") {
                    if origin == .host { model.setHostChoice(.monitoring, for: target, nil) }
                    if !model.isEnabled(.monitoring, for: target) { model.setHostChoice(.monitoring, for: target, true) }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}
