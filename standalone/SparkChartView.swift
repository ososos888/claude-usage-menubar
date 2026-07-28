import AppKit

// A small cumulative usage chart for the current session, shown at the top of the dropdown.
// The x-axis is the FIXED 5-hour session window, labeled 0h…5h from the reset (session
// start). The line covers only actually-measured samples, so the unmeasured parts (before
// recording started, and the future after "now") are left blank.
final class SparkChartView: NSView {
    private let points: [HistoryPoint]
    private let domainMin: Double   // session start (reset − window length)
    private let domainMax: Double   // session end (reset time)

    init(points: [HistoryPoint], windowStart: Double, windowEnd: Double, frame: NSRect) {
        self.points = points
        if windowEnd > windowStart, windowStart > 0 {   // fixed session window
            domainMin = windowStart; domainMax = windowEnd
        } else {                                         // fall back to the data span
            domainMin = points.first?.t ?? 0; domainMax = (points.last?.t ?? 1) + 1
        }
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let leftAxis: CGFloat = 26, padTop: CGFloat = 8, padBottom: CGFloat = 15, padRight: CGFloat = 8
        let plot = NSRect(x: bounds.minX + leftAxis, y: bounds.minY + padBottom,
                          width: bounds.width - leftAxis - padRight, height: bounds.height - padTop - padBottom)
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 9),
                                                     .foregroundColor: NSColor.secondaryLabelColor]
        let tiny: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 8),
                                                    .foregroundColor: NSColor.tertiaryLabelColor]
        guard points.count >= 2, plot.width > 4, plot.height > 4 else {
            ("collecting…" as NSString).draw(at: NSPoint(x: plot.minX, y: bounds.midY - 6), withAttributes: small)
            return
        }
        let tMin = domainMin, tMax = max(domainMax, domainMin + 1)
        let span = tMax - tMin
        func x(_ t: Double) -> CGFloat { plot.minX + plot.width * CGFloat((t - tMin) / span) }
        let pcts = points.map { $0.pct }
        let maxP = max(pcts.max() ?? 0, 1)
        func y(_ p: Int) -> CGFloat { plot.minY + plot.height * CGFloat(p) / CGFloat(maxP) }

        // y-axis labels
        ("\(maxP)%" as NSString).draw(at: NSPoint(x: bounds.minX + 2, y: plot.maxY - 6), withAttributes: small)
        ("0%" as NSString).draw(at: NSPoint(x: bounds.minX + 2, y: plot.minY - 5), withAttributes: small)

        // dotted hourly gridlines from the session start: 0h, 1h, 2h … up to the window length
        let hours = max(1, Int((span / 3600).rounded()))
        for k in 0 ... hours {
            let gx = x(tMin + Double(k) * 3600)
            let grid = NSBezierPath()
            grid.move(to: NSPoint(x: gx, y: plot.minY)); grid.line(to: NSPoint(x: gx, y: plot.maxY))
            grid.lineWidth = 0.75
            grid.setLineDash([1.5, 2.5], count: 2, phase: 0)
            NSColor.separatorColor.setStroke(); grid.stroke()
            let ns = "\(k)h" as NSString
            let w = ns.size(withAttributes: tiny).width
            ns.draw(at: NSPoint(x: min(max(gx - w / 2, plot.minX - 6), plot.maxX - w + 4), y: bounds.minY + 2), withAttributes: tiny)
        }

        // baseline
        NSColor.separatorColor.setStroke()
        let base = NSBezierPath()
        base.move(to: NSPoint(x: plot.minX, y: plot.minY)); base.line(to: NSPoint(x: plot.maxX, y: plot.minY))
        base.lineWidth = 1; base.stroke()

        // usage line + area — measured samples only (blank before first sample and after "now")
        let line = NSBezierPath()
        line.move(to: NSPoint(x: x(points[0].t), y: y(pcts[0])))
        for p in points.dropFirst() { line.line(to: NSPoint(x: x(p.t), y: y(p.pct))) }
        let area = line.copy() as! NSBezierPath
        area.line(to: NSPoint(x: x(points.last!.t), y: plot.minY))
        area.line(to: NSPoint(x: x(points[0].t), y: plot.minY))
        area.close()
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill(); area.fill()
        NSColor.controlAccentColor.setStroke(); line.lineWidth = 1.5; line.stroke()
        // current-value dot (marks "now")
        let last = NSPoint(x: x(points.last!.t), y: y(pcts[pcts.count - 1]))
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)).fill()
    }
}
