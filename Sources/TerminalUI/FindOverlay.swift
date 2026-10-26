import AppKit
import TetherCore
import TerminalText

/// Draws a find over the terminal: the current match's line, the current match (a solid box with
/// its text on top, bouncing when reached), the other matches, and marks beside the scroller for
/// every match in the history. It only draws; `TetherTerminalView` says what and where.
final class FindOverlay {
    /// Where things are on screen, worked out by the view.
    struct Geometry {
        var bounds: CGRect
        var cell: CGSize
        /// Scroll-invariant row at the top of the screen, and the screen's height in rows.
        var topRow: Int
        var rows: Int
        /// Width the text uses (without the scroller).
        var textWidth: CGFloat
        /// The scroller's frame, when one is shown (marks are drawn on it).
        var scroller: CGRect?
        /// First scroll-invariant row of the buffer and how many rows it has (for the marks).
        var firstRow: Int
        var lineCount: Int

        func rect(row: Int, columns: Range<Int>) -> CGRect? {
            let v = row - topRow
            guard v >= 0, v < rows else { return nil }
            return CGRect(x: CGFloat(columns.lowerBound) * cell.width, y: bounds.maxY - CGFloat(v + 1) * cell.height,
                          width: CGFloat(columns.count) * cell.width, height: cell.height)
        }
    }

    let root = CALayer()
    private let line = CAShapeLayer()
    private let lineEdge = CAShapeLayer()
    private let others = CAShapeLayer()
    private let current = CALayer()
    private let marks = CAShapeLayer()
    private let currentMark = CAShapeLayer()

    init() {
        root.zPosition = 10
        root.masksToBounds = true
        for l in [line, lineEdge, others, current, marks, currentMark] {
            root.addSublayer(l)
        }
        for l in [line, lineEdge, others, marks, currentMark] {
            l.actions = ["path": NSNull(), "fillColor": NSNull()]
        }
    }

    func remove() { root.removeFromSuperlayer() }

    /// Redraws for the matches and the current one (an index into `matches`).
    /// - Parameter text: the characters of a row's cells, for drawing the current match's text.
    func update(matches: [BufferMatch], current index: Int?, geometry g: Geometry, style: FindHighlightStyle,
                font: NSFont, scale: CGFloat, appearance: NSAppearance, text: (Int, Range<Int>) -> [(Int, String)]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        root.frame = g.bounds
        appearance.performAsCurrentDrawingAppearance {
            let lineColor = style.lineColor.nsColor
            let matchColor = style.matchColor.nsColor
            let currentMatch = index.flatMap { matches.indices.contains($0) ? matches[$0] : nil }

            // The current match's line, across the terminal, with a stronger edge on the left.
            let linePath = CGMutablePath(), edgePath = CGMutablePath()
            if style.highlightLine, let m = currentMatch {
                for row in m.rows {
                    guard let r = g.rect(row: row, columns: 0..<1) else { continue }
                    linePath.addRect(CGRect(x: 0, y: r.minY, width: g.textWidth, height: r.height))
                    edgePath.addRect(CGRect(x: 0, y: r.minY, width: 3, height: r.height))
                }
            }
            line.path = linePath
            line.fillColor = lineColor.withAlphaComponent(0.2).cgColor
            lineEdge.path = edgePath
            lineEdge.fillColor = lineColor.withAlphaComponent(0.9).cgColor

            // The other matches on screen.
            let othersPath = CGMutablePath()
            if style.showOtherMatches {
                var i = Self.firstIndex(in: matches, atOrAfter: g.topRow - 4)
                while i < matches.count, matches[i].row < g.topRow + g.rows {
                    if i != index {
                        for s in matches[i].segments {
                            if let r = g.rect(row: s.row, columns: s.columns) {
                                othersPath.addRoundedRect(in: r.insetBy(dx: 0, dy: 1), cornerWidth: 2, cornerHeight: 2)
                            }
                        }
                    }
                    i += 1
                }
            }
            others.path = othersPath
            others.fillColor = matchColor.withAlphaComponent(0.33).cgColor

            // The current match: a solid box per row with the text drawn again on top.
            var boxes: [(CGRect, [(Int, String)])] = []
            if let m = currentMatch {
                for s in m.segments {
                    if let r = g.rect(row: s.row, columns: s.columns) { boxes.append((r, text(s.row, s.columns))) }
                }
            }
            if boxes.isEmpty {
                current.isHidden = true
            } else {
                let frame = boxes.map(\.0).reduce(boxes[0].0) { $0.union($1) }.insetBy(dx: -2, dy: -1)
                current.isHidden = false
                current.bounds = CGRect(origin: .zero, size: frame.size)
                current.position = CGPoint(x: frame.midX, y: frame.midY)
                current.shadowColor = NSColor.black.cgColor
                current.shadowOpacity = 0.35
                current.shadowRadius = 2
                current.shadowOffset = CGSize(width: 0, height: -1)
                let ink = matchColor.findTextColor
                current.sublayers = boxes.map { r, cells in
                    let l = MatchBoxLayer()
                    l.frame = r.offsetBy(dx: -frame.minX, dy: -frame.minY).insetBy(dx: -2, dy: -1)
                    l.cells = cells
                    l.cellWidth = g.cell.width
                    l.font = font
                    l.fill = matchColor.cgColor
                    l.ink = ink.cgColor
                    l.contentsScale = scale
                    l.setNeedsDisplay()
                    return l
                }
            }

            // Marks on the scroller: every match, and the current one wider.
            let marksPath = CGMutablePath(), currentPath = CGMutablePath()
            if style.showScrollerMarks, let track = g.scroller, g.lineCount > 0 {
                let inset = track.insetBy(dx: 3, dy: 2)
                func y(_ row: Int) -> CGFloat {
                    let f = CGFloat(row - g.firstRow) / CGFloat(max(g.lineCount, 1))
                    return (inset.maxY - f * inset.height).rounded()
                }
                var last = CGFloat.nan
                for (i, m) in matches.enumerated() where i != index {
                    let p = y(m.row)
                    if p == last { continue }
                    last = p
                    marksPath.addRect(CGRect(x: inset.minX + 2, y: p - 1, width: max(inset.width - 4, 2), height: 2))
                }
                if let m = currentMatch {
                    currentPath.addRoundedRect(in: CGRect(x: inset.minX, y: y(m.row) - 1.5, width: inset.width, height: 3),
                                               cornerWidth: 1.5, cornerHeight: 1.5)
                }
            }
            marks.path = marksPath
            marks.fillColor = matchColor.withAlphaComponent(0.85).cgColor
            currentMark.path = currentPath
            currentMark.fillColor = lineColor.cgColor
        }
    }

    /// Draws attention to the current match after a jump.
    func announce(_ effect: FindJumpEffect) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        if effect.bounces, !current.isHidden {
            let bounce = CAKeyframeAnimation(keyPath: "transform.scale")
            bounce.values = [1, 1.45, 0.92, 1.06, 1]
            bounce.keyTimes = [0, 0.3, 0.6, 0.8, 1]
            bounce.duration = 0.4
            bounce.timingFunction = CAMediaTimingFunction(name: .easeOut)
            current.add(bounce, forKey: "bounce")
        }
        if effect.blinks {
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            blink.values = [1, 0.15, 1]
            blink.duration = 0.45
            line.add(blink, forKey: "blink")
            lineEdge.add(blink, forKey: "blink")
        }
    }

    /// Index of the first match on `row` or later (matches are sorted top to bottom).
    static func firstIndex(in matches: [BufferMatch], atOrAfter row: Int) -> Int {
        var lo = 0, hi = matches.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if matches[mid].rows.upperBound < row { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

/// One row of the current match: a rounded box in the match color with the cells' text on top.
private final class MatchBoxLayer: CALayer {
    var cells: [(Int, String)] = []
    var cellWidth: CGFloat = 0
    var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    var fill = NSColor.systemYellow.cgColor
    var ink = NSColor.black.cgColor

    override func draw(in ctx: CGContext) {
        ctx.setFillColor(fill)
        ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.fillPath()
        // The same baseline the terminal uses: the descent and leading above the cell's bottom.
        let base = ceil(CTFontGetDescent(font) + CTFontGetLeading(font)) + 1
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let first = cells.first?.0 ?? 0
        for (col, text) in cells {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            ctx.textPosition = CGPoint(x: 2 + CGFloat(col - first) * cellWidth, y: base)
            CTLineDraw(line, ctx)
        }
    }
}

extension FindHighlightColor {
    var nsColor: NSColor {
        switch self {
        case .accent: .controlAccentColor
        case .yellow: .systemYellow
        case .orange: .systemOrange
        case .green: .systemGreen
        case .blue: .systemBlue
        case .pink: .systemPink
        case .purple: .systemPurple
        }
    }
}

private extension NSColor {
    /// Black or white, whichever reads better on this color.
    var findTextColor: NSColor {
        guard let c = usingColorSpace(.sRGB) else { return .black }
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luminance > 0.55 ? .black : .white
    }
}
