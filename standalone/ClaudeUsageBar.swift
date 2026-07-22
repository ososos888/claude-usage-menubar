// ClaudeUsageBar — a single native menu bar app that works without SwiftBar.
// It only reads ~/.claude-usage/usage.json (refreshed by the launchd daemon collect.sh)
// and renders it in the menu bar. Reading a local file only, it triggers virtually no
// macOS permission prompts.
import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private let jsonURL = URL(fileURLWithPath: NSString(string: "~/.claude-usage/usage.json").expandingTildeInPath)
    private let collectPath = NSString(string: "~/.claude-usage/collect.sh").expandingTildeInPath
    private var lastGood: Usage?                 // keep last successful read to avoid flicker
    private let sessionMax = 6 * 3600            // session window is 5h; treat >6h as a mid-reset artifact
    private let weeklyMax  = 8 * 86400           // weekly window is 7d; treat >8d as a mid-reset artifact

    // Animations (toggleable, persisted). Spinner while resetting; a pulse when %s change.
    private var animationsEnabled = UserDefaults.standard.object(forKey: "animationsEnabled") as? Bool ?? true
    private let spinnerFrames = ["◐", "◓", "◑", "◒"]
    private var spinTimer: Timer?
    private var spinFrame = 0
    private var prevSession: Int?                // last shown session % (for change detection)
    private var prevWeekly: Int?                 // last shown weekly %
    private var flipTimer: Timer?                // one-off hourglass flip on manual refresh
    private var flipFrame = 0
    private let flipFrames = 16

    struct Usage {
        var sessionPct: Int?; var sessionReset: String?; var sessionEpoch: Double?
        var weeklyPct: Int?;  var weeklyReset: String?;  var weeklyEpoch: Double?
        var modelLabel: String?; var modelPct: Int?
        var error: String?; var collectedAt: String?
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refresh()
        // Reload the file + recompute remaining time every 30s (keeps the ⏳ minute fresh).
        let t = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Data
    private func load() -> Usage? {
        guard let data = try? Data(contentsOf: jsonURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func int(_ k: String) -> Int? { (obj[k] as? Int) ?? (obj[k] as? Double).map { Int($0) } }
        func str(_ k: String) -> String? { obj[k] as? String }
        func dbl(_ k: String) -> Double? { (obj[k] as? Double) ?? (obj[k] as? Int).map { Double($0) } }
        var u = Usage()
        u.sessionPct = int("session_pct"); u.sessionReset = str("session_reset"); u.sessionEpoch = dbl("session_reset_epoch")
        u.weeklyPct = int("weekly_all_pct"); u.weeklyReset = str("weekly_all_reset"); u.weeklyEpoch = dbl("weekly_all_reset_epoch")
        u.modelLabel = str("weekly_model_label"); u.modelPct = int("weekly_model_pct")
        u.error = str("error"); u.collectedAt = str("collected_at")
        return u
    }

    // Human-readable time until reset. `resetting` is true during the brief reset window:
    // just elapsed, about to elapse, or an implausibly large value from a mid-reset parse.
    private struct Remain { let text: String; let resetting: Bool }
    private func remaining(_ epoch: Double?, maxSeconds: Int, short: Bool) -> Remain? {
        guard let e = epoch else { return nil }
        let diff = Int(e - Date().timeIntervalSince1970)
        if diff <= 30 || diff > maxSeconds {
            return Remain(text: short ? "resetting" : "resetting…", resetting: true)
        }
        let d = diff / 86400, h = (diff % 86400) / 3600, m = (diff % 3600) / 60
        let text: String
        if short {
            if d > 0 { text = "\(d)d\(h)h" }
            else if h > 0 { text = "\(h)h\(m)m" }
            else { text = "\(m)m" }
        } else {
            if d > 0 { text = "\(d)d \(h)h left" }
            else if h > 0 { text = "\(h)h \(m)m left" }
            else { text = "\(m)m left" }
        }
        return Remain(text: text, resetting: false)
    }

    private func color(forPct p: Int?) -> NSColor? {
        guard let p = p else { return nil }
        if p >= 80 { return .systemRed }
        if p >= 60 { return .systemOrange }
        return nil
    }

    // MARK: - Render
    private func refresh() {
        if let fresh = load() { lastGood = fresh }  // reuse last good on a transient read failure
        guard let u = lastGood else {
            setTitle("Claude --", color: .systemRed)
            rebuildMenu(nil)
            return
        }
        // Pulse only when the meaningful values (%) change, not when the ⏳ minute ticks.
        let changed = animationsEnabled
            && ((prevSession != nil && prevSession != u.sessionPct)
                || (prevWeekly != nil && prevWeekly != u.weeklyPct))
        prevSession = u.sessionPct
        prevWeekly = u.weeklyPct

        updateStatusItem()
        rebuildMenu(u)

        let resetting = remaining(u.sessionEpoch, maxSeconds: sessionMax, short: true)?.resetting ?? false
        if animationsEnabled && resetting { startSpinner() } else { stopSpinner() }
        if changed { pulse() }
    }

    // Renders the menu bar from lastGood. Used by refresh() and the spinner tick.
    // With animations on: a drawn hourglass icon whose sand reflects session time left
    //   (stepped ~hourly), a spinner while resetting, and a pulse on value change.
    // With animations off: the plain ⏳/↻ emoji, no motion.
    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        if flipTimer != nil { return }  // a refresh flip owns the icon until it finishes
        guard let u = lastGood else { button.image = nil; setTitle("Claude --", color: .systemRed); return }
        let s = u.sessionPct.map(String.init) ?? "?"
        let w = u.weeklyPct.map(String.init) ?? "?"
        var title = "s\(s)% · w\(w)%"  // s = session (5-hour rolling), w = weekly
        let r = remaining(u.sessionEpoch, maxSeconds: sessionMax, short: true)
        if let r = r, r.resetting {
            button.image = nil
            let icon = animationsEnabled ? spinnerFrames[spinFrame % spinnerFrames.count] : "↻"
            title += " · \(icon) resetting"
        } else if let r = r, animationsEnabled, let epoch = u.sessionEpoch {
            let diff = Int(epoch - Date().timeIntervalSince1970)
            button.image = hourglassImage(remaining: diff, windowHours: 5)  // sand = session time left
            button.imagePosition = .imageTrailing
            button.imageHugsTitle = true
            title += " · \(r.text)"
        } else if let r = r {
            button.image = nil
            title += " · ⏳\(r.text)"
        } else {
            button.image = nil
        }
        setTitle(title, color: color(forPct: u.sessionPct))
    }

    // A template hourglass image; sand level = remaining/window, quantized to whole hours
    // so it visibly changes about once per hour.
    // scaleY animates a flip about the horizontal axis (1 upright, 0 edge-on, -1 upside down).
    private func hourglassImage(remaining: Int, windowHours: Int, scaleY: CGFloat = 1) -> NSImage {
        let hoursLeft = max(0, Int(ceil(Double(remaining) / 3600.0)))
        let frac = min(1.0, Double(min(hoursLeft, windowHours)) / Double(max(1, windowHours)))
        let size = NSSize(width: 11, height: 15)
        let line: CGFloat = 1.1
        let img = NSImage(size: size)
        img.lockFocus()
        defer { img.unlockFocus(); img.isTemplate = true }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return img }
        let w = size.width, h = size.height
        let p: CGFloat = line + 0.5
        let cx = w / 2, cy = h / 2, topY = h - p, botY = p, cap = p
        if scaleY != 1 {  // vertical scale about the center → clean flip, no horizontal clipping
            ctx.translateBy(x: 0, y: cy); ctx.scaleBy(x: 1, y: scaleY == 0 ? 0.001 : scaleY); ctx.translateBy(x: 0, y: -cy)
        }
        NSColor.black.setStroke(); NSColor.black.setFill()
        let top = NSBezierPath()
        top.move(to: NSPoint(x: cap, y: topY)); top.line(to: NSPoint(x: w - cap, y: topY)); top.line(to: NSPoint(x: cx, y: cy)); top.close()
        let bot = NSBezierPath()
        bot.move(to: NSPoint(x: cap, y: botY)); bot.line(to: NSPoint(x: w - cap, y: botY)); bot.line(to: NSPoint(x: cx, y: cy)); bot.close()
        ctx.saveGState(); top.addClip()
        NSBezierPath(rect: NSRect(x: 0, y: cy, width: w, height: CGFloat(frac) * (topY - cy))).fill()
        ctx.restoreGState()
        ctx.saveGState(); bot.addClip()
        NSBezierPath(rect: NSRect(x: 0, y: botY, width: w, height: CGFloat(1 - frac) * (cy - botY))).fill()
        ctx.restoreGState()
        top.lineWidth = line; top.stroke(); bot.lineWidth = line; bot.stroke()
        let caps = NSBezierPath(); caps.lineWidth = line
        caps.move(to: NSPoint(x: cap - line / 2, y: topY)); caps.line(to: NSPoint(x: w - cap + line / 2, y: topY))
        caps.move(to: NSPoint(x: cap - line / 2, y: botY)); caps.line(to: NSPoint(x: w - cap + line / 2, y: botY))
        caps.stroke()
        return img
    }

    // Spinner: cycle the reset glyph while resetting (only runs during that brief window).
    private func startSpinner() {
        guard spinTimer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.spinFrame &+= 1
            self.updateStatusItem()
        }
        RunLoop.main.add(t, forMode: .common)
        spinTimer = t
    }
    private func stopSpinner() { spinTimer?.invalidate(); spinTimer = nil }

    // Manual-refresh flourish: flip the hourglass one full turn, then settle back upright.
    // Only when animations are on and the hourglass icon is showing (not during a reset).
    private func flipRefreshIcon() {
        guard animationsEnabled, statusItem.button != nil,
              let u = lastGood, let epoch = u.sessionEpoch,
              !(remaining(u.sessionEpoch, maxSeconds: sessionMax, short: true)?.resetting ?? false)
        else { return }
        let diff = Int(epoch - Date().timeIntervalSince1970)
        flipTimer?.invalidate()
        flipFrame = 0
        let t = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            guard let self = self, let btn = self.statusItem.button else { return }
            self.flipFrame += 1
            if self.flipFrame > self.flipFrames {
                self.flipTimer?.invalidate(); self.flipTimer = nil
                self.updateStatusItem()
                return
            }
            let sy = cos(2 * CGFloat.pi * CGFloat(self.flipFrame) / CGFloat(self.flipFrames))
            btn.image = self.hourglassImage(remaining: diff, windowHours: 5, scaleY: sy)
            btn.imagePosition = .imageTrailing
        }
        RunLoop.main.add(t, forMode: .common)
        flipTimer = t
    }

    // Pulse: a quick fade-in of the menu bar text to signal a value change.
    private func pulse() {
        guard let button = statusItem.button else { return }
        button.alphaValue = 0.2
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.5
            button.animator().alphaValue = 1.0
        }
    }

    private func setTitle(_ text: String, color: NSColor?) {
        guard let button = statusItem.button else { return }
        var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.menuBarFont(ofSize: 0)]
        if let c = color { attrs[.foregroundColor] = c }
        button.attributedTitle = NSAttributedString(string: text, attributes: attrs)
    }

    private func rebuildMenu(_ u: Usage?) {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        func info(_ title: String) {
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
        }
        if let u = u {
            if let err = u.error { info("⚠️ Last update failed: \(err) (showing last good values)") }
            let s = u.sessionPct.map(String.init) ?? "?"
            let sRem = remaining(u.sessionEpoch, maxSeconds: sessionMax, short: false)?.text ?? "resets \(u.sessionReset ?? "?")"
            info("Session: \(s)% used · \(sRem)")
            let w = u.weeklyPct.map(String.init) ?? "?"
            let wRem = remaining(u.weeklyEpoch, maxSeconds: weeklyMax, short: false)?.text ?? "resets \(u.weeklyReset ?? "?")"
            info("Weekly (all models): \(w)% used · \(wRem)")
            if let ml = u.modelLabel, let mp = u.modelPct { info("Weekly (\(ml)): \(mp)%") }
            menu.addItem(.separator())
            info("Updated: \(u.collectedAt ?? "?")")
        } else {
            info("No data (daemon not running?)")
        }
        add(menu, "Refresh now", #selector(refreshNow), key: "r")
        add(menu, "Open usage page", #selector(openUsage), key: "")
        let anim = NSMenuItem(title: "Animations", action: #selector(toggleAnimations), keyEquivalent: "")
        anim.target = self
        anim.state = animationsEnabled ? .on : .off
        menu.addItem(anim)
        menu.addItem(.separator())
        add(menu, "Quit", #selector(quit), key: "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, key: String) {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        menu.addItem(it)
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    // MARK: - Actions
    @objc private func refreshNow() {
        flipRefreshIcon()  // immediate visual feedback
        let p = Process()
        p.executableURL = URL(fileURLWithPath: collectPath)
        p.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
        try? p.run()
    }
    @objc private func openUsage() {
        if let url = URL(string: "https://claude.ai/settings/usage") { NSWorkspace.shared.open(url) }
    }
    @objc private func toggleAnimations() {
        animationsEnabled.toggle()
        UserDefaults.standard.set(animationsEnabled, forKey: "animationsEnabled")
        if !animationsEnabled { stopSpinner() }
        updateStatusItem()
        rebuildMenu(lastGood)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // Menu-bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
