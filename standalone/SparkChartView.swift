import AppKit

// One provider's usage line: its samples plus the session window they belong to. The window
// is what makes two providers comparable — Claude and Codex reset at different wall-clock
// times, so the x-axis is "hours since this window's start", not absolute time.
struct ChartSeries {
    let points: [HistoryPoint]
    let windowStart: Double
    let windowEnd: Double
    let color: NSColor
    let label: String

    var windowKnown: Bool { windowEnd > windowStart && windowStart > 0 }
    var windowLength: Double { windowKnown ? windowEnd - windowStart : 5 * 3600 }
}

// A cumulative usage chart for the current session. Used small (top of the dropdown) and
// large (the enlarge window), with one series or two overlaid. Both axes are fixed so the
// shape is comparable between sessions and between providers: x is the session window
// labeled 0h…5h from the start, y is the full 0…100% budget with solid gridlines every 25%.
// Each line covers only actually-measured samples (unmeasured parts stay blank).
// Fonts/strokes scale with the view height.
final class SparkChartView: NSView {
    private let series: [ChartSeries]
    private let title: String?
    private let onClick: (() -> Void)?
    private let domainSpan: Double   // seconds across the x-axis (the longest window shown)
    private let knownWindow: Bool    // false when a domain had to be inferred from samples

    init(series: [ChartSeries], title: String? = nil, frame: NSRect, onClick: (() -> Void)? = nil) {
        self.series = series
        self.title = title
        self.onClick = onClick
        self.knownWindow = !series.isEmpty && series.allSatisfy { $0.windowKnown }
        // Both providers run a 5-hour window today. Taking the longest keeps the axis honest
        // if that ever differs: the shorter series simply stops before the right edge.
        self.domainSpan = max(series.map { $0.windowLength }.max() ?? 5 * 3600, 1)
        super.init(frame: frame)
    }
    // Convenience for the single-provider case.
    convenience init(points: [HistoryPoint], windowStart: Double, windowEnd: Double, frame: NSRect,
                     color: NSColor = .controlAccentColor, label: String = "", title: String? = nil,
                     onClick: (() -> Void)? = nil) {
        self.init(series: [ChartSeries(points: points, windowStart: windowStart, windowEnd: windowEnd,
                                       color: color, label: label)],
                  title: title, frame: frame, onClick: onClick)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) {
        guard onClick != nil else { return }
        enclosingMenuItem?.menu?.cancelTracking()   // dismiss the dropdown, then act
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let sc = min(max(bounds.height / 82, 1), 1.9)   // scale factor (1 small … ~1.9 large)
        let leftAxis = 26 * sc, padTop = (title == nil ? 8 : 20) * sc, padBottom = 16 * sc, padRight = 8 * sc
        let plot = NSRect(x: bounds.minX + leftAxis, y: bounds.minY + padBottom,
                          width: bounds.width - leftAxis - padRight, height: bounds.height - padTop - padBottom)
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 9 * sc),
                                                     .foregroundColor: NSColor.secondaryLabelColor]
        let tiny: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 8 * sc),
                                                    .foregroundColor: NSColor.tertiaryLabelColor]
        if let t = title {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 10 * sc),
                                                        .foregroundColor: NSColor.secondaryLabelColor]
            (t as NSString).draw(at: NSPoint(x: bounds.minX + 2, y: bounds.maxY - 15 * sc), withAttributes: attrs)
        }
        let drawable = series.filter { $0.points.count >= 2 }
        guard !drawable.isEmpty, plot.width > 4, plot.height > 4 else {
            ("collecting…" as NSString).draw(at: NSPoint(x: plot.minX, y: bounds.midY - 6 * sc), withAttributes: small)
            return
        }
        // The y-axis is always the full 0…100% budget, so a line's height means the same thing
        // between sessions (auto-scaling to the peak made 4% look like a full bar).
        func y(_ p: Int) -> CGFloat { plot.minY + plot.height * CGFloat(p) / 100 }
        // x is elapsed seconds into the series' own window, so two providers whose windows
        // start at different times still line up by session progress.
        func x(_ t: Double, _ s: ChartSeries) -> CGFloat {
            let origin = s.windowKnown ? s.windowStart : (s.points.first?.t ?? t)
            let frac = (t - origin) / domainSpan
            return plot.minX + plot.width * CGFloat(min(max(frac, 0), 1))
        }

        // solid gridlines every 25%; label them all unless the view is too short to fit
        let labelEvery25 = plot.height >= 70
        for pct in stride(from: 0, through: 100, by: 25) {
            let gy = y(pct)
            if pct > 0 {
                let grid = NSBezierPath()
                grid.move(to: NSPoint(x: plot.minX, y: gy)); grid.line(to: NSPoint(x: plot.maxX, y: gy))
                grid.lineWidth = (pct == 100 ? 0.75 : 0.5) * sc
                NSColor.separatorColor.setStroke(); grid.stroke()
            }
            guard labelEvery25 || pct % 50 == 0 else { continue }
            let ns = "\(pct)%" as NSString
            let h = ns.size(withAttributes: small).height
            ns.draw(at: NSPoint(x: bounds.minX + 2, y: gy - h / 2), withAttributes: small)
        }

        // dotted hourly gridlines from the session start: 0h, 1h, 2h …
        let hours = max(1, Int((domainSpan / 3600).rounded()))
        for k in 0 ... hours {
            let gx = plot.minX + plot.width * CGFloat(min(Double(k) * 3600 / domainSpan, 1))
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

        // Pace reference: spending the whole budget evenly over the window, 0% at 0h to 100%
        // at 5h. Below it, usage is on pace to last the session; above it, the budget runs out
        // early. Only drawn when the real windows are known — against a sample-inferred domain
        // the slope would be meaningless. Dashed grey, and drawn under the data lines (which
        // stay the subject).
        if knownWindow {
            let pace = NSBezierPath()
            pace.move(to: NSPoint(x: plot.minX, y: y(0))); pace.line(to: NSPoint(x: plot.maxX, y: y(100)))
            pace.lineWidth = 1 * sc
            pace.setLineDash([4 * sc, 3 * sc], count: 2, phase: 0)
            NSColor.secondaryLabelColor.withAlphaComponent(0.45).setStroke(); pace.stroke()
            if labelEvery25 {   // only the large view has room for it
                let ns = "even pace" as NSString
                let size = ns.size(withAttributes: tiny)
                // sit just under the line at ~70% across, where the data line rarely reaches
                let lx = plot.minX + plot.width * 0.70
                ns.draw(at: NSPoint(x: lx, y: y(70) - size.height - 2 * sc), withAttributes: tiny)
            }
        }

        for s in drawable {
            let pts = s.points
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x(pts[0].t, s), y: y(pts[0].pct)))
            for p in pts.dropFirst() { line.line(to: NSPoint(x: x(p.t, s), y: y(p.pct))) }
            // Fill only a lone series: two translucent areas stacked on each other read as a
            // third colour and hide where the lines actually cross.
            if drawable.count == 1 {
                let area = line.copy() as! NSBezierPath
                area.line(to: NSPoint(x: x(pts.last!.t, s), y: plot.minY))
                area.line(to: NSPoint(x: x(pts[0].t, s), y: plot.minY))
                area.close()
                s.color.withAlphaComponent(0.18).setFill(); area.fill()
            }
            s.color.setStroke(); line.lineWidth = 1.5 * sc; line.stroke()
            let last = NSPoint(x: x(pts.last!.t, s), y: y(pts.last!.pct))
            let r = 2.5 * sc
            s.color.setFill()
            NSBezierPath(ovalIn: NSRect(x: last.x - r, y: last.y - r, width: r * 2, height: r * 2)).fill()
        }

        // Legend, only when two lines share the plot and both are labeled.
        guard drawable.count > 1 else { return }
        var lx = plot.maxX - 3 * sc   // small inset so the last glyph can't touch the edge
        for s in drawable.reversed() where !s.label.isEmpty {
            let ns = s.label as NSString
            let size = ns.size(withAttributes: tiny)
            lx -= size.width
            ns.draw(at: NSPoint(x: lx, y: plot.maxY - size.height - 1 * sc), withAttributes: tiny)
            let dot = 4 * sc
            lx -= dot + 3 * sc
            s.color.setFill()
            NSBezierPath(ovalIn: NSRect(x: lx, y: plot.maxY - size.height / 2 - dot / 2 - 1 * sc,
                                        width: dot, height: dot)).fill()
            lx -= 8 * sc
        }
    }
}
