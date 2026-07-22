// ClaudeUsageBar — a single native menu bar app that works without SwiftBar.
// It only reads ~/.claude-usage/usage.json (refreshed by the launchd daemon collect.sh)
// and renders it in the menu bar. Reading a local file only, it triggers virtually no
// macOS permission prompts.
import Cocoa
import UserNotifications

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
    private var spinTimer: Timer?
    private var spinFrame = 0
    private var prevSession: Int?                // last shown session % (for change detection)
    private var prevWeekly: Int?                 // last shown weekly %
    private var prevSessionEpoch: Double?        // last seen session reset time (for reset detection)
    private var flipTimer: Timer?                // one-off hourglass flip on manual refresh
    private var flipFrame = 0
    private let flipFrames = 16

    // Usage alerts (opt-in, persisted): notify once when a metric crosses the threshold.
    private var alertsEnabled = UserDefaults.standard.bool(forKey: "usageAlerts")
    private var alertThreshold = UserDefaults.standard.object(forKey: "alertThreshold") as? Int ?? 80
    private var sessionAlerted = false
    private var weeklyAlerted = false
    // Emphasize (red) when the session is about to reset.
    private let imminentSeconds = 15 * 60
    // Auto-start at login is driven by the launchd agent; toggle enables/disables it.
    private let agentLabel = "com.ososos888.claudeusagebar"
    private lazy var startAtLoginEnabled: Bool = queryStartAtLogin()

    // Compact mode: show only the session item to save menu bar width.
    private var compactEnabled = UserDefaults.standard.bool(forKey: "compactMode")
    // Stale detection: if the collector hasn't updated checked_at in this long, dim + warn.
    private let iso = ISO8601DateFormatter()
    private let staleSeconds: Double = 180
    // While the menu is open the status button is highlighted; drop explicit colors then so
    // the text inverts properly on the blue highlight.
    private var menuOpen = false
    private let repoURL = "https://github.com/ososos888/claude-usage-menubar"
    private var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }

    struct Usage {
        var sessionPct: Int?; var sessionReset: String?; var sessionEpoch: Double?
        var weeklyPct: Int?;  var weeklyReset: String?;  var weeklyEpoch: Double?
        var modelLabel: String?; var modelPct: Int?
        var error: String?; var collectedAt: String?; var checkedAt: String?
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        if alertsEnabled { requestNotificationAuth() }
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
        u.error = str("error"); u.collectedAt = str("collected_at"); u.checkedAt = str("checked_at")
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
            statusItem.button?.toolTip = "No data (daemon not running?)"
            setTitle("Claude --", color: .systemRed)
            rebuildMenu(nil)
            return
        }
        let oldEpoch = prevSessionEpoch
        // Pulse only when the meaningful values (%) change, not when the ⏳ minute ticks.
        let changed = animationsEnabled
            && ((prevSession != nil && prevSession != u.sessionPct)
                || (prevWeekly != nil && prevWeekly != u.weeklyPct))
        prevSession = u.sessionPct
        prevWeekly = u.weeklyPct
        prevSessionEpoch = u.sessionEpoch

        statusItem.button?.toolTip = toolTipText(u)
        statusItem.button?.setAccessibilityLabel(accessibilityText(u))
        updateStatusItem()
        rebuildMenu(u)
        if alertsEnabled {
            checkAlerts(u)
            // A real reset advances the reset time to a new window. Keying off this (not a %
            // dip, which happens on its own as a rolling window ages) avoids false alarms.
            if let ne = u.sessionEpoch, let oe = oldEpoch, ne > oe + 60 {
                postNotification(title: "Claude usage", body: "Session reset — full capacity available")
            }
        }

        let resetting = remaining(u.sessionEpoch, maxSeconds: sessionMax, short: true)?.resetting ?? false
        if animationsEnabled && resetting { startSpinner() } else { stopSpinner() }
        if changed { pulse() }
    }

    private func toolTipText(_ u: Usage) -> String {
        var lines: [String] = []
        let s = u.sessionPct.map(String.init) ?? "?"
        let sRem = remaining(u.sessionEpoch, maxSeconds: sessionMax, short: false)?.text ?? "resets \(u.sessionReset ?? "?")"
        lines.append("Session: \(s)% used · \(sRem)")
        let w = u.weeklyPct.map(String.init) ?? "?"
        let wRem = remaining(u.weeklyEpoch, maxSeconds: weeklyMax, short: false)?.text ?? "resets \(u.weeklyReset ?? "?")"
        lines.append("Weekly (all models): \(w)% used · \(wRem)")
        if let ml = u.modelLabel, let mp = u.modelPct { lines.append("Weekly (\(ml)): \(mp)%") }
        if let ca = u.collectedAt { lines.append("Updated: \(ca)") }
        if isStale(u) { lines.append("⚠ Data may be stale — the collector daemon may have stopped.") }
        return lines.joined(separator: "\n")
    }

    private func epoch(fromISO s: String?) -> Double? {
        guard let s = s, let d = iso.date(from: s) else { return nil }
        return d.timeIntervalSince1970
    }
    private func isStale(_ u: Usage) -> Bool {
        guard let e = epoch(fromISO: u.checkedAt) else { return false }
        return Date().timeIntervalSince1970 - e > staleSeconds
    }
    private func accessibilityText(_ u: Usage) -> String {
        let s = u.sessionPct.map(String.init) ?? "unknown"
        let w = u.weeklyPct.map(String.init) ?? "unknown"
        var t = "Claude usage. Session \(s) percent. Weekly \(w) percent."
        if let r = remaining(u.sessionEpoch, maxSeconds: sessionMax, short: false) {
            t += r.resetting ? " Session resetting." : " Session \(r.text)."
        }
        if isStale(u) { t += " Data may be stale." }
        return t
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
        // Stale data (collector stopped): dim and mark, don't imply the old numbers are live.
        if isStale(u) {
            button.image = nil
            let body = compactEnabled ? "⚠ s\(s)%" : "⚠ s\(s)% · w\(w)%"
            setSegments([(body, .secondaryLabelColor)])
            return
        }
        // Each item is colored by its own state (session %, weekly %, time-left).
        var segs: [(String, NSColor?)] = [("s\(s)%", color(forPct: u.sessionPct))]
        if !compactEnabled {
            segs.append((" · ", nil))
            segs.append(("w\(w)%", color(forPct: u.weeklyPct)))
        }
        let r = remaining(u.sessionEpoch, maxSeconds: sessionMax, short: true)
        if let r = r, r.resetting {
            if animationsEnabled {
                button.imagePosition = .imageTrailing   // the spinner timer drives the rotating icon
                segs.append((" · resetting", nil))
            } else {
                button.image = nil
                segs.append((" · ↻ resetting", nil))
            }
        } else if let r = r, animationsEnabled, let epoch = u.sessionEpoch {
            let diff = Int(epoch - Date().timeIntervalSince1970)
            button.image = hourglassImage(remaining: diff, windowHours: 5)  // sand = session time left
            button.imagePosition = .imageTrailing
            button.imageHugsTitle = true
            segs.append((" · ", nil))
            segs.append((r.text, timeColor(u.sessionEpoch)))
        } else if let r = r {
            button.image = nil
            segs.append((" · ⏳", nil))
            segs.append((r.text, timeColor(u.sessionEpoch)))
        } else {
            button.image = nil
        }
        setSegments(segs)
    }

    // Color for the time-left item: orange within 60 min of reset, red within 15 min.
    private func timeColor(_ epoch: Double?) -> NSColor? {
        guard let e = epoch else { return nil }
        let diff = Int(e - Date().timeIntervalSince1970)
        if diff <= 30 { return nil }                 // resetting is handled elsewhere
        if diff <= imminentSeconds { return .systemRed }
        if diff <= 60 * 60 { return .systemOrange }
        return nil
    }

    // A template hourglass image; sand level = remaining/window, quantized to whole hours
    // so it visibly changes about once per hour.
    //   scaleY — flip about the horizontal axis (1 upright, 0 edge-on, -1 upside down).
    //   angle  — true rotation (for the resetting spinner).
    //   spinning — draw in a square canvas so rotation never clips and the width stays fixed.
    private func hourglassImage(remaining: Int, windowHours: Int,
                                scaleY: CGFloat = 1, angle: CGFloat = 0, spinning: Bool = false) -> NSImage {
        let hoursLeft = max(0, Int(ceil(Double(remaining) / 3600.0)))
        let frac = min(1.0, Double(min(hoursLeft, windowHours)) / Double(max(1, windowHours)))
        let bw: CGFloat = 11, bh: CGFloat = 15, line: CGFloat = 1.1
        let size = spinning ? NSSize(width: 21, height: 21) : NSSize(width: bw, height: bh)
        let img = NSImage(size: size)
        img.lockFocus()
        defer { img.unlockFocus(); img.isTemplate = true }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return img }
        // Transform about the canvas center: rotate, then vertical scale (flip).
        ctx.translateBy(x: size.width / 2, y: size.height / 2)
        if angle != 0 { ctx.rotate(by: angle) }
        if scaleY != 1 { ctx.scaleBy(x: 1, y: scaleY == 0 ? 0.001 : scaleY) }
        ctx.translateBy(x: -size.width / 2, y: -size.height / 2)
        // Hourglass geometry inside its bw×bh box, centered in the (possibly square) canvas.
        let ox = (size.width - bw) / 2, oy = (size.height - bh) / 2, p = line + 0.5
        let cx = ox + bw / 2, cy = oy + bh / 2, topY = oy + bh - p, botY = oy + p, capL = ox + p, capR = ox + bw - p
        NSColor.black.setStroke(); NSColor.black.setFill()
        let top = NSBezierPath()
        top.move(to: NSPoint(x: capL, y: topY)); top.line(to: NSPoint(x: capR, y: topY)); top.line(to: NSPoint(x: cx, y: cy)); top.close()
        let bot = NSBezierPath()
        bot.move(to: NSPoint(x: capL, y: botY)); bot.line(to: NSPoint(x: capR, y: botY)); bot.line(to: NSPoint(x: cx, y: cy)); bot.close()
        ctx.saveGState(); top.addClip()
        NSBezierPath(rect: NSRect(x: ox, y: cy, width: bw, height: CGFloat(frac) * (topY - cy))).fill()
        ctx.restoreGState()
        ctx.saveGState(); bot.addClip()
        NSBezierPath(rect: NSRect(x: ox, y: botY, width: bw, height: CGFloat(1 - frac) * (cy - botY))).fill()
        ctx.restoreGState()
        top.lineWidth = line; top.stroke(); bot.lineWidth = line; bot.stroke()
        let caps = NSBezierPath(); caps.lineWidth = line
        caps.move(to: NSPoint(x: capL - line / 2, y: topY)); caps.line(to: NSPoint(x: capR + line / 2, y: topY))
        caps.move(to: NSPoint(x: capL - line / 2, y: botY)); caps.line(to: NSPoint(x: capR + line / 2, y: botY))
        caps.stroke()
        return img
    }

    // Spinner: smoothly rotate the hourglass icon while resetting (fixed-size square canvas,
    // so no width jitter). Only runs during that brief window.
    private func startSpinner() {
        guard spinTimer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, let btn = self.statusItem.button else { return }
            self.spinFrame &+= 1
            let angle = 2 * CGFloat.pi * CGFloat(self.spinFrame % 40) / 40  // ~2s per revolution
            btn.image = self.hourglassImage(remaining: 0, windowHours: 5, angle: angle, spinning: true)
            btn.imagePosition = .imageTrailing
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

    // MARK: - Alerts
    private func requestNotificationAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    private func checkAlerts(_ u: Usage) {
        evalAlert(name: "Session", pct: u.sessionPct, alerted: &sessionAlerted)
        evalAlert(name: "Weekly",  pct: u.weeklyPct,  alerted: &weeklyAlerted)
    }
    private func evalAlert(name: String, pct: Int?, alerted: inout Bool) {
        guard let p = pct else { return }
        if p >= alertThreshold {
            if !alerted {
                postNotification(title: "Claude usage", body: "\(name) usage at \(p)% (alert at \(alertThreshold)%)")
                alerted = true
            }
        } else {
            alerted = false   // re-arm once it drops back below the threshold (e.g. after reset)
        }
    }
    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Start at login (via the launchd agent; enable/disable does not kill the running app)
    @discardableResult
    private func runLaunchctl(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
    private func queryStartAtLogin() -> Bool {
        if let out = runLaunchctl(["print-disabled", "gui/\(getuid())"]) {
            // Output format varies by macOS: `"label" => disabled` (or `=> true`) means off.
            if out.contains("\"\(agentLabel)\" => disabled") || out.contains("\"\(agentLabel)\" => true")  { return false }
            if out.contains("\"\(agentLabel)\" => enabled")  || out.contains("\"\(agentLabel)\" => false") { return true }
        }
        // No explicit override → enabled if the agent plist exists.
        return FileManager.default.fileExists(
            atPath: NSString(string: "~/Library/LaunchAgents/\(agentLabel).plist").expandingTildeInPath)
    }
    private func setStartAtLogin(_ on: Bool) {
        runLaunchctl([on ? "enable" : "disable", "gui/\(getuid())/\(agentLabel)"])
    }

    private func setTitle(_ text: String, color: NSColor?) {
        setSegments([(text, color)])
    }

    // Build the menu bar title from colored segments (nil color = default/adaptive).
    private func setSegments(_ segments: [(String, NSColor?)]) {
        guard let button = statusItem.button else { return }
        let font = NSFont.menuBarFont(ofSize: 0)
        let result = NSMutableAttributedString()
        for (text, color) in segments {
            var attrs: [NSAttributedString.Key: Any] = [.font: font]
            // While the menu is open, let the system color the (highlighted) text.
            if let c = color, !menuOpen { attrs[.foregroundColor] = c }
            result.append(NSAttributedString(string: text, attributes: attrs))
        }
        button.attributedTitle = result
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
        add(menu, "Copy status", #selector(copyStatus), key: "")
        add(menu, "Open usage page", #selector(openUsage), key: "")
        menu.addItem(.separator())
        addCheck(menu, "Animations", #selector(toggleAnimations), on: animationsEnabled)
        addCheck(menu, "Compact (session only)", #selector(toggleCompact), on: compactEnabled)
        // Usage alerts: Off / 70% / 80% / 90%
        let alertsItem = NSMenuItem(title: "Usage alerts", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let off = NSMenuItem(title: "Off", action: #selector(setAlertOption(_:)), keyEquivalent: "")
        off.target = self; off.tag = 0; off.state = alertsEnabled ? .off : .on
        sub.addItem(off)
        for thr in [70, 80, 90] {
            let it = NSMenuItem(title: "\(thr)%", action: #selector(setAlertOption(_:)), keyEquivalent: "")
            it.target = self; it.tag = thr
            it.state = (alertsEnabled && alertThreshold == thr) ? .on : .off
            sub.addItem(it)
        }
        alertsItem.submenu = sub
        menu.addItem(alertsItem)
        addCheck(menu, "Start at login", #selector(toggleStartAtLogin), on: startAtLoginEnabled)
        menu.addItem(.separator())
        add(menu, "About (v\(appVersion))", #selector(openAbout), key: "")
        add(menu, "Quit", #selector(quit), key: "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, key: String) {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        menu.addItem(it)
    }
    private func addCheck(_ menu: NSMenu, _ title: String, _ sel: Selector, on: Bool) {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        it.target = self
        it.state = on ? .on : .off
        menu.addItem(it)
    }

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true; refresh() }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false; updateStatusItem() }

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
    @objc private func copyStatus() {
        guard let u = lastGood else { return }
        let s = u.sessionPct.map(String.init) ?? "?"
        let w = u.weeklyPct.map(String.init) ?? "?"
        var str = "s\(s)% · w\(w)%"
        if let r = remaining(u.sessionEpoch, maxSeconds: sessionMax, short: true) {
            str += r.resetting ? " · resetting" : " · \(r.text)"
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(str, forType: .string)
    }
    @objc private func setAlertOption(_ sender: NSMenuItem) {
        if sender.tag == 0 {
            alertsEnabled = false
        } else {
            alertsEnabled = true
            alertThreshold = sender.tag
            sessionAlerted = false; weeklyAlerted = false
            requestNotificationAuth()
        }
        UserDefaults.standard.set(alertsEnabled, forKey: "usageAlerts")
        UserDefaults.standard.set(alertThreshold, forKey: "alertThreshold")
        rebuildMenu(lastGood)
    }
    @objc private func toggleCompact() {
        compactEnabled.toggle()
        UserDefaults.standard.set(compactEnabled, forKey: "compactMode")
        updateStatusItem()
        rebuildMenu(lastGood)
    }
    @objc private func openAbout() {
        if let url = URL(string: repoURL) { NSWorkspace.shared.open(url) }
    }
    @objc private func toggleStartAtLogin() {
        startAtLoginEnabled.toggle()
        setStartAtLogin(startAtLoginEnabled)
        rebuildMenu(lastGood)
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
