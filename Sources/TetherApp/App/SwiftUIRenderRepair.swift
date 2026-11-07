import QuartzCore
import ObjectiveC

/// Repairs a SwiftUI/AppKit layer race that could draw text upside down on early macOS 26 releases.
/// macOS 26.2 fixes it in the framework, so older systems alone receive the redraw.
enum SwiftUIRenderRepair {
    static func install() {
        guard #unavailable(macOS 26.2) else { return }
        _ = installed
    }

    private static let installed: Void = {
        guard let original = class_getInstanceMethod(CALayer.self, #selector(CALayer.didChangeValue(forKey:))),
              let replacement = class_getInstanceMethod(CALayer.self, #selector(CALayer.tether_didChangeValue(forKey:))) else { return }
        method_exchangeImplementations(original, replacement)
    }()
}

private extension CALayer {
    @objc func tether_didChangeValue(forKey key: String) {
        tether_didChangeValue(forKey: key)
        // A layer's flipped coordinate state can change before its ancestors are attached. Asking
        // Core Animation for one more draw happens after that transaction has settled.
        if key == "contentsAreFlipped" { setNeedsDisplay() }
    }
}
