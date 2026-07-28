import AppKit

// A small line/area chart of session usage over the current window, shown at the top of the
// dropdown. Decorative (non-interactive); resets with each session (history is per-window).
final class SparkChartView: NSView {
    private let points: [HistoryPoint]

    init(points: [HistoryPoint], frame: NSRect) {
        self.points = points
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let leftAxis: CGFloat = 26, pad: CGFloat = 8
        let plot = NSRect(x: bounds.minX + leftAxis, y: bounds.minY + pad,
                          width: bounds.width - leftAxis - pad, height: bounds.height - pad * 2)
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 9),
                                                     .foregroundColor: NSColor.secondaryLabelColor]
        guard points.count >= 2, plot.width > 4, plot.height > 4 else {
            ("collecting…" as NSString).draw(at: NSPoint(x: plot.minX, y: bounds.midY - 6), withAttributes: small)
            return
        }
        let pcts = points.map { $0.pct }
        let maxP = max(pcts.max() ?? 0, 1)     // full-height = current window's peak (min 1 to avoid /0)
        let n = points.count
        func pt(_ i: Int) -> NSPoint {
            NSPoint(x: plot.minX + plot.width * CGFloat(i) / CGFloat(n - 1),
                    y: plot.minY + plot.height * CGFloat(pcts[i]) / CGFloat(maxP))
        }
        // y-axis labels
        ("\(maxP)%" as NSString).draw(at: NSPoint(x: bounds.minX + 2, y: plot.maxY - 6), withAttributes: small)
        ("0%" as NSString).draw(at: NSPoint(x: bounds.minX + 2, y: plot.minY - 4), withAttributes: small)
        // baseline
        NSColor.separatorColor.setStroke()
        let base = NSBezierPath()
        base.move(to: NSPoint(x: plot.minX, y: plot.minY)); base.line(to: NSPoint(x: plot.maxX, y: plot.minY))
        base.lineWidth = 1; base.stroke()
        // line
        let line = NSBezierPath()
        line.move(to: pt(0))
        for i in 1 ..< n { line.line(to: pt(i)) }
        // area under the line
        let area = line.copy() as! NSBezierPath
        area.line(to: NSPoint(x: plot.maxX, y: plot.minY))
        area.line(to: NSPoint(x: plot.minX, y: plot.minY))
        area.close()
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill(); area.fill()
        NSColor.controlAccentColor.setStroke(); line.lineWidth = 1.5; line.stroke()
        // current-value dot
        let last = pt(n - 1)
        let dot = NSBezierPath(ovalIn: NSRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5))
        NSColor.controlAccentColor.setFill(); dot.fill()
    }
}
