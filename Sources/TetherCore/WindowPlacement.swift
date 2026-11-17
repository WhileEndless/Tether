import Foundation
import CoreGraphics

/// Display-independent geometry, also used when a saved monitor no longer exists.
public enum WindowPlacement {
    public static func fitted(_ frame: CGRect, to screens: [CGRect]) -> CGRect {
        let screens = screens.filter { valid($0) && $0.width > 0 && $0.height > 0 }
        guard valid(frame), frame.width > 0, frame.height > 0, !screens.isEmpty else { return frame }
        if screens.contains(where: { $0.contains(frame) }) { return frame }
        func area(_ s: CGRect) -> CGFloat {
            let i = s.intersection(frame)
            return i.isNull ? 0 : i.width * i.height
        }
        func distance(_ s: CGRect) -> CGFloat {
            let dx = s.midX - frame.midX, dy = s.midY - frame.midY
            return dx * dx + dy * dy
        }
        let screen = screens.max { a, b in
            let aa = area(a), ab = area(b)
            return aa == ab ? distance(a) > distance(b) : aa < ab
        }!
        let width = min(frame.width, screen.width), height = min(frame.height, screen.height)
        return CGRect(x: min(max(frame.minX, screen.minX), screen.maxX - width),
                      y: min(max(frame.minY, screen.minY), screen.maxY - height), width: width, height: height)
    }

    private static func valid(_ r: CGRect) -> Bool {
        [r.origin.x, r.origin.y, r.width, r.height].allSatisfy(\.isFinite)
    }
}
