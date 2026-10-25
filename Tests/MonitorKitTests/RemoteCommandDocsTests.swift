import Foundation
import Testing
@testable import MonitorKit

/// docs/remote-commands.md describes every script the app runs on hosts: a new one without a
/// description there fails here, so the page cannot fall behind.
@Suite struct RemoteCommandDocsTests {
    @Test func everyRemoteCommandIsDocumented() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let page = try String(contentsOf: root.appendingPathComponent("docs/remote-commands.md"), encoding: .utf8)
        for c in RemoteCommandCatalog.all {
            #expect(page.contains("### \(c.title)\n"), "docs/remote-commands.md does not describe \"\(c.title)\"")
            #expect(!c.posix.isEmpty)
        }
        #expect(Set(RemoteCommandCatalog.all.map(\.title)).count == RemoteCommandCatalog.all.count)
    }
}
