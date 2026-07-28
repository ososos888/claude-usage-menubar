import AppKit

// A cumulative usage chart for the current session. Used both small (top of the dropdown)
// and large (the enlarge window). The x-axis is the fixed 5-hour session window labeled
// 0h…5h from the reset; the line covers only actually-measured samples (unmeasured parts
// stay blank). Fonts/strokes scale with the view height, so it reads well at any size.
final class SparkChartView: NSView {
    private let points: [HistoryPoint]
    private let domainMin: Double   // session start (reset − window length)
    private let domainMax: Double   // session end (reset time)
    private let onClick: (() -> Void)?

    init(points: [HistoryPoint], windowStart: Double, windowEnd: Double, frame: NSRect,
         onClick: (() -> Void)? = nil) {
        self.points = points
        self.onClick = onClick
        if windowEnd > windowStart, windowStart > 0 {
            domainMin = windowStart; domainMax = windowEnd
        } else {
            domainMin = points.first?.t ?? 0; domainMax = (points.last?.t ?? 1) + 1
        }
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) {
        guard onClick != nil else { return }
        enclosingMenuItem?.menu?.cancelTracking()   // dismiss the dropdown, then act
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let sc = min(max(bounds.height / 82, 1), 1.9)   // scale factor (1 small … ~1.9 large)
        let leftAxis = 26 * sc, padTop = 8 * sc, padBottom = 16 * sc, padRight = 8 * sc
        let plot = NSRect(x: bounds.minX + leftAxis, y: bounds.minY + padBottom,
                          width: bounds.width - leftAxis - padRight, height: bounds.height - padTop - padBottom)
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 9 * sc),
                                                     .foregroundColor: NSColor.secondaryLabelColor]
        let tiny: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 8 * sc),
                                                    .foregroundColor: NSColor.tertiaryLabelColor]
        guard points.count >= 2, plot.width > 4, plot.height > 4 else {
            ("collecting…" as NSString).draw(at: NSPoint(x: plot.minX, y: bounds.midY - 6 * sc), withAttributes: small)
            return
        }
        let tMin = domainMin, tMax = max(domainMax, domainMin + 1)
        let span = tMax - tMin
        func x(_ t: Double) -> CGFloat { plot.minX + plot.width * CGFloat((t - tMin) / span) }
        let pcts = points.map { $0.pct }
        let maxP = max(pcts.max() ?? 0, 1)
        func y(_ p: Int) -> CGFloat { plot.minY + plot.height * CGFloat(p) / CGFloat(maxP) }

        ("\(maxP)%" as NSString).draw(at: NSPoint(x: bounds.minX + 2, y: plot.maxY - 6 * sc), withAttributes: small)
        ("0%" as NSString).draw(at: NSPoint(x: bounds.minX + 2, y: plot.minY - 5 * sc), withAttributes: small)

        // dotted hourly gridlines from the session start: 0h, 1h, 2h …
        let hours = max(1, Int((span / 3600).rounded()))
        for k in 0 ... hours {
            let gx = x(tMin + Double(k) * 3600)
            let grid = NSBezierPath()
            grid.move(to: NSPoint(x: gx, y: plot.minY)); grid.line(to: NSPoint(x: gx, y: plot.maxY))
            grid.lineWidth = 0.75 * sc
            grid.setLineDash([1.5 * sc, 2.5 * sc], count: 2, phase: 0)
            NSColor.separatorColor.setStroke(); grid.stroke()
            let ns = "\(k)h" as NSString
            let w = ns.size(withAttributes: tiny).width
            ns.draw(at: NSPoint(x: min(max(gx - w / 2, plot.minX - 6 * sc), plot.maxX - w + 4 * sc), y: bounds.minY + 3 * sc), withAttributes: tiny)
        }

        NSColor.separatorColor.setStroke()
        let base = NSBezierPath()
        base.move(to: NSPoint(x: plot.minX, y: plot.minY)); base.line(to: NSPoint(x: plot.maxX, y: plot.minY))
        base.lineWidth = 1 * sc; base.stroke()

        let line = NSBezierPath()
        line.move(to: NSPoint(x: x(points[0].t), y: y(pcts[0])))
        for p in points.dropFirst() { line.line(to: NSPoint(x: x(p.t), y: y(p.pct))) }
        let area = line.copy() as! NSBezierPath
        area.line(to: NSPoint(x: x(points.last!.t), y: plot.minY))
        area.line(to: NSPoint(x: x(points[0].t), y: plot.minY))
        area.close()
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill(); area.fill()
        NSColor.controlAccentColor.setStroke(); line.lineWidth = 1.5 * sc; line.stroke()
        let last = NSPoint(x: x(points.last!.t), y: y(pcts[pcts.count - 1]))
        let r = 2.5 * sc
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: last.x - r, y: last.y - r, width: r * 2, height: r * 2)).fill()
    }
}
