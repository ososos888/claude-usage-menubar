// ClaudeUsageBar — a native menu bar app that works without SwiftBar.
// It only reads ~/.claude-usage/usage.json (refreshed by the launchd daemon collect.sh)
// and renders it in the menu bar. Pure logic lives in UsageLogic.swift; the hourglass
// drawing in HourglassIcon.swift; the app entry point in main.swift.
import Cocoa
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var napActivity: NSObjectProtocol?   // opt out of App Nap so the timer keeps firing
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
    private var resetPollTimer: Timer?           // fast polling around a reset for a quick update
    private var resetPollCount = 0

    // Usage alerts (opt-in, persisted): notify once when a metric crosses the threshold.
    private var alertsEnabled = UserDefaults.standard.bool(forKey: "usageAlerts")
    private var alertThreshold = UserDefaults.standard.object(forKey: "alertThreshold") as? Int ?? 80
    private var sessionAlerted = false
    private var weeklyAlerted = false
    // Auto-start at login is driven by the launchd agent; toggle enables/disables it.
    private let agentLabel = "com.ososos888.claudeusagebar"
    private lazy var startAtLoginEnabled: Bool = queryStartAtLogin()

    // Compact mode: show only the session item to save menu bar width.
    private var compactEnabled = UserDefaults.standard.bool(forKey: "compactMode")
    // While the menu is open the status button is highlighted; drop explicit colors then so
    // the text inverts properly on the blue highlight.
    private var menuOpen = false
    private let repoURL = "https://github.com/ososos888/claude-usage-menubar"
    private let latestReleaseAPI = "https://api.github.com/repos/ososos888/claude-usage-menubar/releases/latest"
    private var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    private var repoPath: String? { Bundle.main.object(forInfoDictionaryKey: "SourceRepoPath") as? String }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        if alertsEnabled { requestNotificationAuth() }
        // Prevent App Nap from suspending our refresh timer while the Mac is awake
        // (idle system sleep is still allowed — we don't keep the Mac awake).
        napActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep], reason: "Keep menu bar usage up to date")
        // Refresh right away when the Mac wakes (the timer alone can lag after sleep).
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        refresh()
        // Reload the file + recompute remaining time every 30s (keeps the ⏳ minute fresh).
        let t = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Data
    private func load() -> Usage? {
        guard let data = try? Data(contentsOf: jsonURL) else { return nil }
        return Usage.parse(data)
    }

    // Map a severity level to a menu bar color (nil = default/adaptive).
    private func nsColor(_ level: UsageLevel) -> NSColor? {
        switch level {
        case .normal: return nil
        case .warn: return .systemOrange
        case .critical: return .systemRed
        }
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
            // A reset only happens when the countdown expires, so the reset time jumps ~a full
            // window (~5h) forward all at once. The reported time also drifts by a few minutes
            // as a rolling window ages — so require a large jump (>3h) to avoid false alarms.
            if let ne = u.sessionEpoch, let oe = oldEpoch, ne - oe > 3 * 3600 {
                postNotification(title: "Claude usage", body: "Session reset — full capacity available")
            }
        }

        let resetting = remainingTime(epoch: u.sessionEpoch, maxSeconds: sessionMax, short: true)?.resetting ?? false
        if animationsEnabled && resetting { startSpinner() } else { stopSpinner() }
        if changed { pulse() }

        // In the last ~90s before, and during, a reset, poll fast for a near-instant update.
        let secs = u.sessionEpoch.map { Int($0 - Date().timeIntervalSince1970) }
        if resetting || (secs.map { $0 > 0 && $0 <= 90 } ?? false) { startResetPolling() } else { stopResetPolling() }
    }

    private func toolTipText(_ u: Usage) -> String {
        var lines: [String] = []
        let s = u.sessionPct.map(String.init) ?? "?"
        let sRem = remainingTime(epoch: u.sessionEpoch, maxSeconds: sessionMax, short: false)?.text ?? "resets \(u.sessionReset ?? "?")"
        lines.append("Session: \(s)% used · \(sRem)")
        let w = u.weeklyPct.map(String.init) ?? "?"
        let wRem = remainingTime(epoch: u.weeklyEpoch, maxSeconds: weeklyMax, short: false)?.text ?? "resets \(u.weeklyReset ?? "?")"
        lines.append("Weekly (all models): \(w)% used · \(wRem)")
        if let ml = u.modelLabel, let mp = u.modelPct { lines.append("Weekly (\(ml)): \(mp)%") }
        if let ca = u.collectedAt { lines.append("Updated: \(ca)") }
        if isStale(checkedAt: u.checkedAt) { lines.append("⚠ Data may be stale — the collector daemon may have stopped.") }
        return lines.joined(separator: "\n")
    }

    private func accessibilityText(_ u: Usage) -> String {
        let s = u.sessionPct.map(String.init) ?? "unknown"
        let w = u.weeklyPct.map(String.init) ?? "unknown"
        var t = "Claude usage. Session \(s) percent. Weekly \(w) percent."
        if let r = remainingTime(epoch: u.sessionEpoch, maxSeconds: sessionMax, short: false) {
            t += r.resetting ? " Session resetting." : " Session \(r.text)."
        }
        if isStale(checkedAt: u.checkedAt) { t += " Data may be stale." }
        return t
    }

    // Renders the menu bar from lastGood. Used by refresh() and the spinner tick.
    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        if flipTimer != nil { return }  // a refresh flip owns the icon until it finishes
        guard let u = lastGood else { button.image = nil; setTitle("Claude --", color: .systemRed); return }
        let s = u.sessionPct.map(String.init) ?? "?"
        let w = u.weeklyPct.map(String.init) ?? "?"
        // Stale data (collector stopped): dim and mark, don't imply the old numbers are live.
        if isStale(checkedAt: u.checkedAt) {
            button.image = nil
            let body = compactEnabled ? "⚠ s\(s)%" : "⚠ s\(s)% · w\(w)%"
            setSegments([(body, .secondaryLabelColor)])
            return
        }
        // Each item is colored by its own state (session %, weekly %, time-left).
        var segs: [(String, NSColor?)] = [("s\(s)%", nsColor(level(forPct: u.sessionPct)))]
        if !compactEnabled {
            segs.append((" · ", nil))
            segs.append(("w\(w)%", nsColor(level(forPct: u.weeklyPct))))
        }
        let r = remainingTime(epoch: u.sessionEpoch, maxSeconds: sessionMax, short: true)
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
            segs.append((r.text, nsColor(timeLevel(epoch: u.sessionEpoch))))
        } else if let r = r {
            button.image = nil
            segs.append((" · ⏳", nil))
            segs.append((r.text, nsColor(timeLevel(epoch: u.sessionEpoch))))
        } else {
            button.image = nil
        }
        setSegments(segs)
    }

    // Spinner: smoothly rotate the hourglass icon while resetting (fixed-size square canvas,
    // so no width jitter). Only runs during that brief window.
    private func startSpinner() {
        guard spinTimer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, let btn = self.statusItem.button else { return }
            self.spinFrame &+= 1
            let angle = 2 * CGFloat.pi * CGFloat(self.spinFrame % 40) / 40  // ~2s per revolution
            btn.image = hourglassImage(remaining: 0, windowHours: 5, angle: angle, spinning: true)
            btn.imagePosition = .imageTrailing
        }
        RunLoop.main.add(t, forMode: .common)
        spinTimer = t
    }
    private func stopSpinner() { spinTimer?.invalidate(); spinTimer = nil }

    // Around a reset, collect every few seconds so the new window shows within seconds
    // instead of waiting up to a full launchd cycle. Self-stops when the new window loads.
    private func startResetPolling() {
        guard resetPollTimer == nil else { return }
        resetPollCount = 0
        let t = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.resetPollCount += 1
            if self.resetPollCount > 24 { self.stopResetPolling(); return }  // safety cap (~3 min)
            self.runCollect()
        }
        RunLoop.main.add(t, forMode: .common)
        resetPollTimer = t
    }
    private func stopResetPolling() { resetPollTimer?.invalidate(); resetPollTimer = nil; resetPollCount = 0 }

    // Manual-refresh flourish: flip the hourglass one full turn, then settle back upright.
    // Only when animations are on and the hourglass icon is showing (not during a reset).
    private func flipRefreshIcon() {
        guard animationsEnabled, statusItem.button != nil,
              let u = lastGood, let epoch = u.sessionEpoch,
              !(remainingTime(epoch: u.sessionEpoch, maxSeconds: sessionMax, short: true)?.resetting ?? false)
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
            btn.image = hourglassImage(remaining: diff, windowHours: 5, scaleY: sy)
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
            let sRem = remainingTime(epoch: u.sessionEpoch, maxSeconds: sessionMax, short: false)?.text ?? "resets \(u.sessionReset ?? "?")"
            info("Session: \(s)% used · \(sRem)")
            let w = u.weeklyPct.map(String.init) ?? "?"
            let wRem = remainingTime(epoch: u.weeklyEpoch, maxSeconds: weeklyMax, short: false)?.text ?? "resets \(u.weeklyReset ?? "?")"
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
        add(menu, "Check for Updates…", #selector(checkForUpdates), key: "")
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
        runCollect()
    }
    // Kick a background collection; refresh the display when it finishes.
    private func runCollect() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: collectPath)
        p.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
        try? p.run()
    }
    @objc private func systemDidWake() {
        refresh()                 // show the cached values immediately
        runCollect()              // fetch fresh (launchd can lag right after wake)
        // The network may still be coming up — one delayed retry.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.runCollect() }
    }
    @objc private func openUsage() {
        if let url = URL(string: "https://claude.ai/settings/usage") { NSWorkspace.shared.open(url) }
    }
    @objc private func copyStatus() {
        guard let u = lastGood else { return }
        let s = u.sessionPct.map(String.init) ?? "?"
        let w = u.weeklyPct.map(String.init) ?? "?"
        var str = "s\(s)% · w\(w)%"
        if let r = remainingTime(epoch: u.sessionEpoch, maxSeconds: sessionMax, short: true) {
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
    // MARK: - Update
    @objc private func checkForUpdates() {
        guard let url = URL(string: latestReleaseAPI) else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("ClaudeUsageBar", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let data = data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = obj["tag_name"] as? String else {
                    self.updateAlert(latest: nil, message: err?.localizedDescription ?? "Could not reach GitHub.")
                    return
                }
                self.updateAlert(latest: tag.trimmingCharacters(in: CharacterSet(charactersIn: "v")), message: nil)
            }
        }.resume()
    }
    private func updateAlert(latest: String?, message: String?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        if let message = message {
            alert.messageText = "Update check failed"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal(); return
        }
        let latestV = latest ?? "", cur = appVersion
        let updatePath = repoPath.map { $0 + "/update.command" }
        if compareVersions(latestV, cur) > 0, let path = updatePath, FileManager.default.fileExists(atPath: path) {
            alert.messageText = "Update available"
            alert.informativeText = "v\(latestV) is available (you have v\(cur)).\nUpdate now? A Terminal window will pull the latest and rebuild; the app restarts automatically."
            alert.addButton(withTitle: "Update"); alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = [path]
                try? p.run()
            }
        } else if compareVersions(latestV, cur) > 0 {
            alert.messageText = "Update available (v\(latestV))"
            alert.informativeText = "You have v\(cur). Update manually:\n  git pull && ./standalone/build.sh"
            alert.addButton(withTitle: "Open project page"); alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn { openAbout() }
        } else {
            alert.messageText = "You're up to date"
            alert.informativeText = "ClaudeUsageBar v\(cur) is the latest version."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
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
