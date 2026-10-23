import SwiftUI

/// A primary view plus a secondary pane of fixed, user-adjustable size, separated by a draggable
/// divider. Pure SwiftUI on purpose: AppKit-backed HSplitView/VSplitView let wrapping text in a pane
/// and the split view re-measure each other until AppKit gives up ("more Update Constraints in
/// Window passes than there are views").
struct ResizablePane<Primary: View, Secondary: View>: View {
    enum Axis { case horizontal, vertical }

    let axis: Axis
    @Binding var size: Double
    let range: ClosedRange<Double>
    @ViewBuilder var primary: Primary
    @ViewBuilder var secondary: Secondary
    @State private var dragStart: Double?

    var body: some View {
        switch axis {
        case .horizontal:
            HStack(spacing: 0) {
                primary.frame(maxWidth: .infinity, maxHeight: .infinity)
                handle
                secondary.frame(width: size).frame(maxHeight: .infinity)
            }
        case .vertical:
            VStack(spacing: 0) {
                primary.frame(maxWidth: .infinity, maxHeight: .infinity)
                handle
                secondary.frame(height: size).frame(maxWidth: .infinity)
            }
        }
    }

    private var handle: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .separatorColor))
                .frame(width: axis == .horizontal ? 1 : nil, height: axis == .vertical ? 1 : nil)
        }
        .frame(width: axis == .horizontal ? 7 : nil, height: axis == .vertical ? 7 : nil)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
        }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if dragStart == nil { dragStart = size }
                // The secondary pane sits after the divider, so dragging towards it shrinks it.
                let delta = axis == .horizontal ? value.translation.width : value.translation.height
                size = min(max((dragStart ?? size) - delta, range.lowerBound), range.upperBound)
            }
            .onEnded { _ in dragStart = nil })
    }
}
