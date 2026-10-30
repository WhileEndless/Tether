import Foundation
import Testing

/// A window whose view reads the app model from the environment must be given it: SwiftUI ends the
/// app when such a window opens without it. Checked in the app's source (the app target itself
/// cannot be loaded by tests).
@Suite struct SceneEnvironmentTests {
    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/TetherApp")

    /// The files that define each view type, by name.
    static func viewFiles() -> [String: String] {
        var out: [String: String] = [:]
        let e = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = e?.nextObject() as? URL {
            guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let pattern = try! NSRegularExpression(pattern: #"struct (\w+)\s*:\s*(?:[\w, ]*\b)?View\b[^{]*\{"#)
            let ns = text as NSString
            let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for (k, m) in matches.enumerated() {
                let end = k + 1 < matches.count ? matches[k + 1].range.location : ns.length
                out[ns.substring(with: m.range(at: 1))] = ns.substring(with: NSRange(location: m.range.location, length: end - m.range.location))
            }
        }
        return out
    }

    @Test func everyWindowThatNeedsTheModelGetsIt() throws {
        let app = try String(contentsOf: Self.sources.appendingPathComponent("App/TetherApp.swift"), encoding: .utf8)
        let views = Self.viewFiles()
        // Each scene: from its opening to the next one.
        let starts = try NSRegularExpression(pattern: #"\n        (Window|WindowGroup|Settings|MenuBarExtra)\b"#)
        let ns = app as NSString
        let found = starts.matches(in: app, range: NSRange(location: 0, length: ns.length))
        #expect(found.count >= 5, "scenes found: \(found.count)")
        for (k, m) in found.enumerated() {
            let end = k + 1 < found.count ? found[k + 1].range.location : ns.length
            let scene = ns.substring(with: NSRange(location: m.range.location, length: end - m.range.location))
            // The first view the scene shows.
            guard let root = try NSRegularExpression(pattern: #"\{[^\n]*\n\s*(?:if [^\n]*\n\s*)?(\w+)\("#)
                .firstMatch(in: scene, range: NSRange(location: 0, length: (scene as NSString).length))
                .map({ (scene as NSString).substring(with: $0.range(at: 1)) }) else { continue }
            // The app's appearance and lock modifiers read the model too (`AppearanceStyle`).
            let modifiers = scene.contains(".tetherAppearance(") || scene.contains(".appLockCover(")
            guard modifiers || views[root]?.contains("@Environment(AppModel.self)") == true else { continue }
            #expect(scene.contains(".environment(model)"), "\(root)'s window reads the model from the environment but does not give it")
        }
    }
}
