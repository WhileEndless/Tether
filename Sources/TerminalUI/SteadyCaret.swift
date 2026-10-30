import AppKit
import ObjectiveC
import SwiftTerm
import TetherCore

/// Keeps SwiftTerm's cursor view from making the whole window lay out again on every frame.
///
/// SwiftTerm moves its cursor view's frame whenever the cursor moves, and takes the view out of
/// the hierarchy and puts it back each time a program hides and shows the cursor — coding agents
/// do both on every frame they draw. Each of these makes AppKit lay out the window again, SwiftUI
/// included (measured: one window layout per frame, about 5 % of a core in an empty window and far
/// more in Tether's). So in Tether's terminals:
/// - the cursor view takes no autoresizing constraints (its frame is set directly, as SwiftTerm
///   does), so moving it changes no layout;
/// - it stays in the view: "removing" it hides its layer instead (`install`), and the terminal shows
///   it again when the cursor is visible (`syncCaret`).
enum SteadyCaret {
    private static var installed = false
    /// Debug builds only: off with TETHER_NO_STEADY_CARET, to measure what it saves.
    private static let disabledForMeasuring = AppPaths.debugOverride("TETHER_NO_STEADY_CARET") != nil

    /// Replaces `removeFromSuperview` for SwiftTerm's cursor view class only (other views are not
    /// touched): inside a Tether terminal it hides the layer; anywhere else it removes as before.
    static func install() {
        guard !installed, !disabledForMeasuring else { return }
        installed = true
        guard let caretClass = NSClassFromString("SwiftTerm.CaretView"),
              let inherited = class_getInstanceMethod(NSView.self, #selector(NSView.removeFromSuperview)) else { return }
        typealias Remove = @convention(c) (AnyObject, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(inherited), to: Remove.self)
        let replacement: @convention(block) (NSView) -> Void = { view in
            // Only while the terminal is shown (SwiftTerm hiding the cursor); a terminal going away
            // (out of its window, being freed) takes its subviews out as usual.
            if let superview = view.superview, superview.window != nil,
               superview is TetherTerminalView || superview is HistoryTerminalView {
                view.wantsLayer = true
                view.layer?.isHidden = true
            } else {
                original(view, #selector(NSView.removeFromSuperview))
            }
        }
        // Added to the cursor class itself (it does not override the method): NSView's own stays as it is.
        class_addMethod(caretClass, #selector(NSView.removeFromSuperview), imp_implementationWithBlock(replacement),
                        method_getTypeEncoding(inherited))
    }

    /// The terminal's cursor view (SwiftTerm's), set up to move without layout.
    static func prepare(_ terminal: TerminalView) {
        guard !disabledForMeasuring else { return }
        install()
        guard let caret = caretView(of: terminal) else { return }
        caret.translatesAutoresizingMaskIntoConstraints = false
        caret.wantsLayer = true
    }

    static func caretView(of terminal: TerminalView) -> NSView? {
        terminal.subviews.first { NSStringFromClass(type(of: $0)).hasSuffix("CaretView") }
    }

    /// Shows the cursor view's layer when the program shows the cursor (`shown`, from SwiftTerm's
    /// show/hide calls) and its row is on screen (`onScreen`).
    static func sync(_ terminal: TerminalView, shown: Bool, onScreen: Bool) {
        guard !disabledForMeasuring, let caret = caretView(of: terminal) else { return }
        if caret.translatesAutoresizingMaskIntoConstraints { prepare(terminal) }
        guard let layer = caret.layer else { return }
        let visible = shown && onScreen
        if layer.isHidden == visible { layer.isHidden = !visible }
    }
}
