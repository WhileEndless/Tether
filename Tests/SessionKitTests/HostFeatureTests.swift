import Foundation
import Testing
import TetherCore

/// What runs for a host: the host's own choice, then the system setting; monitoring off stops
/// everything that reads the host's system.
@Suite struct HostFeatureTests {
    @Test func hostChoiceComesBeforeTheSystemSetting() {
        var s = AppSettings()
        #expect(s.isEnabled(.kubernetesPanel, host: nil) == (true, .system))
        s.setEnabled(.kubernetesPanel, false)
        #expect(s.isEnabled(.kubernetesPanel, host: nil) == (false, .system))
        #expect(s.isEnabled(.kubernetesPanel, host: ["kubernetesPanel": true]) == (true, .host))
        s.setEnabled(.kubernetesPanel, true)
        #expect(s.hostFeatures.isEmpty)                        // only switched-off ones are stored
        #expect(s.isEnabled(.kubernetesPanel, host: ["kubernetesPanel": false]) == (false, .host))
    }

    @Test func monitoringOffStopsWhatReadsTheHost() {
        var s = AppSettings()
        let off = ["monitoring": false]
        #expect(s.isEnabled(.processesPanel, host: off) == (false, .monitoringOff))
        #expect(s.isEnabled(.processesPanel, host: off.merging(["processesPanel": true]) { a, _ in a }) == (false, .monitoringOff))
        #expect(s.isEnabled(.filesPanel, host: off).on)       // browsing files is not monitoring
        #expect(s.isEnabled(.portsPanel, host: off).on)
        s.setEnabled(.monitoring, false)
        #expect(!s.monitorAutoLoad)
        #expect(s.isEnabled(.statusStrip, host: nil) == (false, .monitoringOff))
        #expect(s.isEnabled(.statusStrip, host: ["monitoring": true]).on)    // a host can opt back in
    }

    @Test func longStandingSettingsAreTheSystemSwitches() {
        var s = AppSettings()
        s.setEnabled(.statusStrip, false)
        s.setEnabled(.commandHistory, false)
        #expect(!s.showStatusStrip && !s.keepCommandHistory)
        #expect(s.hostFeatures.isEmpty)
    }

    @Test func oldLibrariesAndSettingsStillDecode() throws {
        let meta = try JSONDecoder().decode(HostMetadata.self, from: Data(#"{"color":"none","favorite":false,"notes":""}"#.utf8))
        #expect(meta.features == nil)
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"version":4}"#.utf8))
        #expect(settings.hostFeatures.isEmpty && settings.hideAbsentToolPanels)
        var m = HostMetadata()
        m.features = ["gpuPanel": false]
        let back = try JSONDecoder().decode(HostMetadata.self, from: JSONEncoder().encode(m))
        #expect(back.features == ["gpuPanel": false])
    }
}

/// On a network device only what needs no script stays possible.
@Suite struct DeviceFeatureTests {
    @Test func onlyScriptFreeFeaturesOnDevices() {
        let scriptFree = HostFeature.allCases.filter { !$0.needsScripts }
        #expect(Set(scriptFree) == [.portsPanel, .agentStatus, .tabActivity])
        #expect(HostFeature.monitoring.needsScripts && HostFeature.filesPanel.needsScripts && HostFeature.keyLoginCheck.needsScripts)
    }
}
