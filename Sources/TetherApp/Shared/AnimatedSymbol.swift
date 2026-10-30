import SwiftUI
import AppKit

/// A symbol that keeps moving while something works (a tab's agent, a running command, a
/// transfer), animated by Core Animation.
///
/// SwiftUI's looping symbol effects (`.pulse`, `.variableColor.iterative`) update SwiftUI on every
/// frame for as long as they run — measured: ten of them take about 10 % of a core in an empty
/// window, far more in Tether's, where each frame redraws the window's views. Here the movement
/// runs in the window server; SwiftUI is not involved until the symbol changes.
struct AnimatedSymbol: NSViewRepresentable {
    enum Motion: Equatable {
        /// Fades in and out.
        case pulse
        /// Turns (a ring of dots: activity).
        case spin
        /// Still.
        case none
    }

    let systemName: String
    var size: CGFloat
    var weight: NSFont.Weight = .regular
    var color: NSColor
    var motion: Motion

    func makeNSView(context: Context) -> SymbolLayerView { SymbolLayerView() }

    func updateNSView(_ view: SymbolLayerView, context: Context) {
        view.set(systemName: systemName, size: size, weight: weight, color: color, motion: motion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SymbolLayerView, context: Context) -> CGSize? {
        CGSize(width: size + 2, height: size + 2)
    }

    /// Draws the symbol into a sublayer and moves that layer (a view's own layer is placed by
    /// AppKit, and would turn about its corner).
    final class SymbolLayerView: NSView {
        private let symbol = CALayer()
        private var shown: (String, CGFloat, NSFont.Weight, NSColor)?
        private var motion: Motion = .none

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(symbol)
            symbol.contentsGravity = .resizeAspect
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override var isFlipped: Bool { true }

        func set(systemName: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, motion: Motion) {
            if shown.map({ $0.0 != systemName || $0.1 != size || $0.2 != weight || $0.3 != color }) ?? true {
                shown = (systemName, size, weight, color)
                render()
            }
            if self.motion != motion || (motion != .none && symbol.animationKeys()?.isEmpty != false) {
                self.motion = motion
                animate()
            }
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            symbol.bounds = bounds
            symbol.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            render()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            render()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { animate() }      // animations do not survive leaving the window
        }

        /// The symbol, tinted, at the screen's scale.
        private func render() {
            guard let (name, size, weight, color) = shown,
                  let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight)) else { return }
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            let appearance = effectiveAppearance
            let tinted = NSImage(size: base.size, flipped: false) { rect in
                base.draw(in: rect)
                appearance.performAsCurrentDrawingAppearance { color.set() }
                rect.fill(using: .sourceAtop)
                return true
            }
            var rect = CGRect(origin: .zero, size: base.size)
            symbol.contents = tinted.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: AffineTransform(scale: scale)])
            symbol.contentsScale = scale
        }

        private func animate() {
            symbol.removeAllAnimations()
            guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            switch motion {
            case .none:
                break
            case .pulse:
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = 1
                a.toValue = 0.3
                a.duration = 0.9
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                symbol.add(a, forKey: "motion")
            case .spin:
                let a = CABasicAnimation(keyPath: "transform.rotation.z")
                a.fromValue = 0
                a.toValue = 2 * Double.pi       // clockwise in a flipped view
                a.duration = 1.6
                a.repeatCount = .infinity
                symbol.add(a, forKey: "motion")
            }
        }
    }
}
