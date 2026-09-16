// ClaudeUsageBar — a native menu bar app that works without SwiftBar.
// It only reads the JSON caches under ~/.claude-usage (refreshed by the launchd daemons
// collect.sh for Claude and collect-codex.sh for Codex) and renders them in the menu bar.
// Codex is optional: when its CLI is missing or signed out the app is Claude-only, exactly
// as before. Pure logic lives in UsageLogic.swift; the hourglass drawing in
// HourglassIcon.swift; the trend chart in SparkChartView.swift; the entry point in main.swift.
import Cocoa
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var napActivity: NSObjectProtocol?   // opt out of App Nap so the timer keeps firing
    private let jsonURL = URL(fileURLWithPath: NSString(string: "~/.claude-usage/usage.json").expandingTildeInPath)
    private let codexJSONURL = URL(fileURLWithPath: NSString(string: "~/.claude-usage/codex-usage.json").expandingTildeInPath)
    private let collectPath = NSString(string: "~/.claude-usage/collect.sh").expandingTildeInPath
    private let codexCollectPath = NSString(string: "~/.claude-usage/collect-codex.sh").expandingTildeInPath
    private let historyURL = URL(fileURLWithPath: NSString(string: "~/.claude-usage/session-history.json").expandingTildeInPath)
    private let codexHistoryURL = URL(fileURLWithPath: NSString(string: "~/.claude-usage/codex-session-history.json").expandingTildeInPath)
    private var history = SessionHistory(windowEpoch: nil, points: [])       // Claude session trend
    private var codexHistory = SessionHistory(windowEpoch: nil, points: [])  // Codex session trend
    private var lastGood: Usage?                 // keep last successful read to avoid flicker
    private var codexLastGood: Usage?
    // Brand colours: Claude orange, Codex blue. They identify a provider wherever both appear
    // together — the C / X tags on the bar and the trend lines in the dropdown — so the same
    // hue always means the same product. Each has a darker shade for light backgrounds and a
    // lighter one for dark, since the menu bar and the menu follow the system appearance.
    private static let claudeInk = dynamicInk(light: NSColor(srgbRed: 0.78, green: 0.38, blue: 0.16, alpha: 1),
                                              dark:  NSColor(srgbRed: 1.00, green: 0.62, blue: 0.40, alpha: 1))
    private static let codexInk  = dynamicInk(light: NSColor(srgbRed: 0.13, green: 0.39, blue: 0.92, alpha: 1),
                                              dark:  NSColor(srgbRed: 0.44, green: 0.66, blue: 1.00, alpha: 1))
    private static func dynamicInk(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
    private func providerColor(_ p: Provider) -> NSColor {
        p == .claude ? AppDelegate.claudeInk : AppDelegate.codexInk
    }
    // The inline hourglass shares the line with text instead of owning the image slot, so it
    // is drawn smaller — two providers plus two icons is a lot of menu bar width.
    private let inlineHourglassScale: CGFloat = 0.78

    // Animations (toggleable, persisted). Spinner while resetting; a pulse when %s change.
    private var animationsEnabled = UserDefaults.standard.object(forKey: "animationsEnabled") as? Bool ?? true
    private var spinTimer: Timer?
    private var spinFrame = 0
    // Per provider, so one provider's numbers can't mask the other's change or reset.
    private var prevSession: [Provider: Int] = [:]        // last shown session % (change detection)
    private var prevWeekly: [Provider: Int] = [:]         // last shown weekly %
    private var prevSessionEpoch: [Provider: Double] = [:]      // last seen session reset time
    private var lastNotifiedResetEpoch: [Provider: Double] = [:] // reset already notified (dedup)
    private var loggedOutNotified = false        // signed-out notice already sent (dedup)
    private var flipTimer: Timer?                // one-off hourglass flip on manual refresh
    private var flipFrame = 0
    private let flipFrames = 16
    private var resetPollTimer: Timer?           // fast polling around a reset for a quick update
    private var resetPollCount = 0

    // Usage alerts (opt-in, persisted): notify once when a metric crosses the threshold.
    private var alertsEnabled = UserDefaults.standard.bool(forKey: "usageAlerts")
    private var alertThreshold = UserDefaults.standard.object(forKey: "alertThreshold") as? Int ?? 80
    // Keys are "<provider>.<metric>": a Claude alert must not suppress the Codex one.
    private var alerted: Set<String> = []
    // Auto-start at login is driven by the launchd agent; toggle enables/disables it.
    private let agentLabel = "com.ososos888.claudeusagebar"
    private lazy var startAtLoginEnabled: Bool = queryStartAtLogin()

    // Compact mode: show only the session item to save menu bar width.
    private var compactEnabled = UserDefaults.standard.bool(forKey: "compactMode")
    // Which providers reach the menu bar, and how the trend chart(s) are drawn.
    private var barMode = BarMode(rawValue: UserDefaults.standard.string(forKey: "barMode") ?? "") ?? .both
    private var chartMode = ChartMode(rawValue: UserDefaults.standard.string(forKey: "chartMode") ?? "") ?? .stacked
    // While the menu is open the status button is highlighted; drop explicit colors then so
    // the text inverts properly on the blue highlight.
    private var menuOpen = false
    private var chartWindow: NSWindow?           // reused enlarge-graph window
    private let repoURL = "https://github.com/ososos888/claude-usage-menubar"
    private let claudeUsageURL = "https://claude.ai/settings/usage"
    private let codexUsageURL = "https://chatgpt.com/codex/settings/usage"
    private let latestReleaseAPI = "https://api.github.com/repos/ososos888/claude-usage-menubar/releases/latest"
    private var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    private var repoPath: String? { Bundle.main.object(forInfoDictionaryKey: "SourceRepoPath") as? String }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        if alertsEnabled { requestNotificationAuth() }
        history = loadHistory(historyURL) ?? history
        codexHistory = loadHistory(codexHistoryURL) ?? codexHistory
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
    private func load(_ url: URL) -> Usage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Usage.parse(data)
    }

    /// Read a persisted trend history, dropping anything corrupt. Returns nil when the file is
    /// missing or unreadable, so the caller keeps its in-memory value.
    private func loadHistory(_ url: URL) -> SessionHistory? {
        guard let d = try? Data(contentsOf: url),
              var h = try? JSONDecoder().decode(SessionHistory.self, from: d) else { return nil }
        h.points = h.points.filter { $0.pct >= 0 && $0.pct <= 100 && $0.t.isFinite && $0.t > 0 }
        var mx = 0   // make older raw-valued history cumulative so the line reads monotonic
        h.points = h.points.map { mx = max(mx, $0.pct); return HistoryPoint(t: $0.t, pct: mx) }
        return h
    }

    /// The Codex reading, but only when it's worth showing (installed, signed in, has numbers).
    private func codexUsage() -> Usage? { isCodexAvailable(codexLastGood) ? codexLastGood : nil }

    /// Every provider currently on screen, in display order.
    private func shownProviders() -> [(Provider, Usage)] {
        var out: [(Provider, Usage)] = []
        if let c = lastGood { out.append((.claude, c)) }
        if let x = codexUsage() { out.append((.codex, x)) }
        return out
    }

    /// What the menu bar should look like right now.
    private func currentRender(now: Date = Date()) -> BarRender {
        menuBarRender(claude: lastGood, codex: codexUsage(), mode: barMode,
                      compact: compactEnabled, animations: animationsEnabled, now: now)
    }

    // Map a severity level to a menu bar color (nil = default/adaptive).
    private func nsColor(_ level: UsageLevel) -> NSColor? {
        switch level {
        case .normal: return nil
        case .warn: return .systemOrange
        case .critical: return .systemRed
        case .dim: return .secondaryLabelColor
        }
    }

    // MARK: - Render
    private func refresh() {
        // Adopt fresh reads, but ignore an oscillation back to an already-expired window
        // (/usage flips between the just-reset old window and the new one for a while).
        if let fresh = load(jsonURL), shouldAdopt(newEpoch: fresh.sessionEpoch, lastEpoch: lastGood?.sessionEpoch) {
            lastGood = fresh
        }
        if let fresh = load(codexJSONURL), shouldAdopt(newEpoch: fresh.sessionEpoch, lastEpoch: codexLastGood?.sessionEpoch) {
            codexLastGood = fresh
        }
        let shown = shownProviders()
        var changed = false
        var resets: [Provider: Double] = [:]
        var needFastPoll = false
        for (p, u) in shown {
            let (ch, reset) = absorb(p, u)
            if animationsEnabled && ch { changed = true }
            if let r = reset { resets[p] = r }
            // Only animate a reset, poll fast, or record history while collection is
            // succeeding. A frozen reset epoch (signed out, collector broken) elapses by
            // itself and would otherwise spin the icon forever and back-fill the chart with
            // re-read stale values.
            guard !isDataUntrusted(u) else { continue }
            recordHistory(p, u)
            // Poll fast in the last ~90s before/during a reset, and while the reset time is
            // missing (right after a reset /usage reports "0% used" with no reset time for a
            // bit).
            let secs = u.sessionEpoch.map { Int($0 - Date().timeIntervalSince1970) }
            if showResetting(u, maxSeconds: sessionMaxSeconds(u))
                || (secs.map { $0 > 0 && $0 <= 90 } ?? false)
                || u.sessionEpoch == nil { needFastPoll = true }
        }

        statusItem.button?.toolTip = tooltipText(claude: lastGood, codex: codexUsage())
        statusItem.button?.setAccessibilityLabel(accessibilityText())
        updateStatusItem()
        rebuildMenu()
        if alertsEnabled {
            for (p, u) in shown {
                checkAlerts(p, u)
                // Fire once when the reset time jumps ~a full window (~5h) forward (a real
                // reset), and never twice for the same new window — dedup guards against any
                // residual flip.
                guard let ne = resets[p] else { continue }
                let last = lastNotifiedResetEpoch[p]
                if last == nil || abs(ne - last!) > 3600 {
                    postNotification(title: "\(p.title) usage", body: "Session reset — full capacity available")
                    lastNotifiedResetEpoch[p] = ne
                }
            }
        }

        // Signed out: say so once per episode. Unlike every other failure this one can't
        // clear up on its own — it needs the user to sign in — so it's worth a notification
        // even when the opt-in usage alerts are off. Only Claude gets this: Codex is opt-in
        // by merely being installed, so its absence is silent by design.
        let claudeOut = lastGood.map(isLoggedOut) ?? false
        if shouldNotifyLogout(loggedOut: claudeOut, alreadyNotified: &loggedOutNotified) {
            postNotification(title: "Claude usage — signed out",
                             body: "Claude Code is signed out, so usage tracking is paused. Sign in from the menu bar.")
        }

        if animationsEnabled && currentRender().icon == .spinner { startSpinner() } else { stopSpinner() }
        if changed { pulse() }
        // Never fast-poll on untrusted data: those conditions would latch and hammer the
        // collectors.
        if needFastPoll { startResetPolling() } else { stopResetPolling() }
    }

    /// Fold one provider's fresh reading into the bookkeeping behind the pulse animation and
    /// the reset notification. Returns whether a percentage changed and, when the session
    /// window jumped a whole window forward, the new reset epoch.
    private func absorb(_ p: Provider, _ u: Usage) -> (changed: Bool, resetEpoch: Double?) {
        // Pulse only when the meaningful values (%) change, not when the ⏳ minute ticks.
        let changed = (prevSession[p] != nil && prevSession[p] != u.sessionPct)
                   || (prevWeekly[p] != nil && prevWeekly[p] != u.weeklyPct)
        let old = prevSessionEpoch[p]
        prevSession[p] = u.sessionPct
        prevWeekly[p] = u.weeklyPct
        prevSessionEpoch[p] = u.sessionEpoch
        var reset: Double?
        if let ne = u.sessionEpoch, let oe = old, ne - oe > 3 * 3600 { reset = ne }
        return (changed, reset)
    }

    /// Record the session-usage trend for one provider; persist only when it actually changes.
    private func recordHistory(_ p: Provider, _ u: Usage) {
        let url = (p == .claude) ? historyURL : codexHistoryURL
        var h = (p == .claude) ? history : codexHistory
        let beforeCount = h.points.count, beforeWindow = h.windowEpoch
        h = updatedHistory(h, sessionEpoch: u.sessionEpoch, pct: u.sessionPct,
                           now: Date().timeIntervalSince1970,
                           windowSeconds: sessionWindowSeconds(u))
        if p == .claude { history = h } else { codexHistory = h }
        if h.points.count != beforeCount || h.windowEpoch != beforeWindow {
            if let d = try? JSONEncoder().encode(h) { try? d.write(to: url) }
        }
    }

    /// Spoken status for VoiceOver: every provider on screen, then any freshness warning.
    private func accessibilityText() -> String {
        let shown = shownProviders()
        guard !shown.isEmpty else { return "Claude usage. No data; the collector may not be running." }
        var parts: [String] = []
        for (p, u) in shown {
            if isLoggedOut(u) {
                parts.append("\(p.title) signed out. Usage tracking is paused; sign in from this menu.")
                continue
            }
            let sp = u.sessionPct.map(String.init) ?? "unknown"
            let wp = u.weeklyPct.map(String.init) ?? "unknown"
            var t = "\(p.title) session \(sp) percent. Weekly \(wp) percent."
            if let r = remainingTime(epoch: u.sessionEpoch, maxSeconds: sessionMaxSeconds(u), short: false) {
                t += r.resetting ? " Session resetting." : " Session \(r.text)."
            }
            if isStale(checkedAt: u.checkedAt) { t += " Data may be stale." }
            parts.append(t)
        }
        return (["Usage."] + parts).joined(separator: " ")
    }

    // Renders the menu bar from the cached readings. Used by refresh() and the spinner tick.
    // The status item has one image slot, so the drawn hourglass stands for a single
    // provider's session; with both on the bar `menuBarRender` asks for no image and the
    // remaining time is a plain ⏳ glyph instead.
    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        if flipTimer != nil { return }  // a refresh flip owns the icon until it finishes
        let render = currentRender()
        switch render.icon {
        case .none:
            button.image = nil
        case .hourglass(let remaining, let windowHours):
            button.image = hourglassImage(remaining: remaining, windowHours: windowHours)
            button.imagePosition = .imageTrailing
            button.imageHugsTitle = true
        case .spinner:
            button.imagePosition = .imageTrailing   // the spinner timer drives the rotating icon
        }
        setSegments(render.segments)
    }

    // Spinner: smoothly rotate the hourglass icon while resetting (fixed-size square canvas,
    // so no width jitter). Only runs during that brief window.
    private func startSpinner() {
        guard spinTimer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, let btn = self.statusItem.button else { return }
            self.spinFrame &+= 1
            // Re-read the cache ~every 1.5s so the display leaves "resetting" as soon as the
            // new window lands in the file (the spinner alone never re-reads).
            if self.spinFrame % 30 == 0 {
                self.refresh()
                if self.spinTimer == nil { return }   // reset finished → stop drawing
            }
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
        let t = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.resetPollCount += 1
            if self.resetPollCount > 40 { self.stopResetPolling(); return }  // safety cap (~3.5 min)
            self.runCollect()
        }
        RunLoop.main.add(t, forMode: .common)
        resetPollTimer = t
    }
    private func stopResetPolling() { resetPollTimer?.invalidate(); resetPollTimer = nil; resetPollCount = 0 }

    // Manual-refresh flourish: flip the hourglass one full turn, then settle back upright.
    // Only when animations are on and the hourglass icon is showing (not during a reset).
    private func flipRefreshIcon() {
        // Only when the hourglass is the current icon: signed out, not updating, mid-reset, or
        // a two-provider bar all render without it, and there'd be nothing to flip.
        guard animationsEnabled, statusItem.button != nil,
              case .hourglass(let diff, let windowHours) = currentRender().icon
        else { return }
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
            btn.image = hourglassImage(remaining: diff, windowHours: windowHours, scaleY: sy)
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
    private func checkAlerts(_ provider: Provider, _ u: Usage) {
        evalAlert(provider, metric: "Session", pct: u.sessionPct)
        evalAlert(provider, metric: "Weekly",  pct: u.weeklyPct)
    }
    private func evalAlert(_ provider: Provider, metric: String, pct: Int?) {
        guard let p = pct else { return }
        let key = "\(provider.rawValue).\(metric)"
        if p >= alertThreshold {
            if !alerted.contains(key) {
                postNotification(title: "\(provider.title) usage",
                                 body: "\(metric) usage at \(p)% (alert at \(alertThreshold)%)")
                alerted.insert(key)
            }
        } else {
            alerted.remove(key)   // re-arm once it drops back below the threshold (e.g. after reset)
        }
    }
    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // Ask before delivering. Authorization is only requested up front when usage alerts are
        // enabled, but the signed-out notice fires regardless — and re-asking once granted is a
        // no-op, so this is safe to do every time.
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
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

    // Build the menu bar title from the rendered segments. A segment carrying an hourglass is
    // drawn as an inline image instead of its text: the status item has one image slot, so
    // embedding the icon in the title is the only way two providers can each show one.
    private func setSegments(_ segments: [Seg]) {
        guard let button = statusItem.button else { return }
        let font = NSFont.menuBarFont(ofSize: 0)
        let result = NSMutableAttributedString()
        for seg in segments {
            if let hg = seg.hourglass {
                // Nothing tints an inline image, so pick the colour here: white while the menu
                // highlight is up, the normal label colour otherwise. Deliberately neutral —
                // the time text next to it carries the warn/critical colour, exactly as the
                // image-slot hourglass did.
                let ink: NSColor = menuOpen ? .selectedMenuItemTextColor : .labelColor
                let img = hourglassImage(remaining: hg.remaining, windowHours: hg.windowHours,
                                         tint: ink, size: inlineHourglassScale)
                let att = NSTextAttachment()
                att.image = img
                // Centre the glyph on the cap-height box so it sits like a character.
                att.bounds = NSRect(x: 0, y: (font.capHeight - img.size.height) / 2,
                                    width: img.size.width, height: img.size.height)
                result.append(NSAttributedString(string: " "))   // keep the space the ⏳ text had
                result.append(NSAttributedString(attachment: att))
                continue
            }
            var attrs: [NSAttributedString.Key: Any] = [.font: font]
            // While the menu is open, let the system color the (highlighted) text.
            if let c = seg.brand.map(providerColor) ?? nsColor(seg.level), !menuOpen {
                attrs[.foregroundColor] = c
            }
            result.append(NSAttributedString(string: seg.text, attributes: attrs))
        }
        button.attributedTitle = result
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        func info(_ title: String) {
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
        }
        // A provider name above its own readings — only worth the row when there are two
        // providers to tell apart.
        func header(_ title: String) {
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            it.isEnabled = false
            it.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor])
            menu.addItem(it)
        }
        let codex = codexUsage()
        let dual = codex != nil

        addCharts(to: menu)

        if let u = lastGood {
            if dual { header("CLAUDE") }
            if isLoggedOut(u) {
                // Signed out: lead with the fix. Showing live-looking figures here would be a
                // lie — report the last measured ones as history instead.
                info("⚠️ Claude Code is signed out — usage tracking is paused")
                add(menu, "Sign in to Claude…", #selector(signIn), key: "")
                menu.addItem(.separator())
                let s = u.sessionPct.map { "\($0)%" } ?? "?"
                let w = u.weeklyPct.map { "\($0)%" } ?? "?"
                info("Last measured: session \(s) · weekly \(w)")
                info("Measured at: \(u.collectedAt ?? "?")")
            } else {
                if let err = u.error { info("⚠️ Last update failed: \(err) (showing last good values)") }
                for line in detailLines(.claude, u) { info(line) }
            }
        } else {
            info("No data (daemon not running?)")
        }
        if let x = codex {
            header("CODEX")
            if let err = x.error { info("⚠️ Last update failed: \(err) (showing last good values)") }
            for line in detailLines(.codex, x) { info(line) }
        }
        menu.addItem(.separator())
        if dual {
            info("Updated: Claude \(lastGood?.collectedAt ?? "?") · Codex \(codex?.collectedAt ?? "?")")
        } else if let u = lastGood, !isLoggedOut(u) {
            info("Updated: \(u.collectedAt ?? "?")")
        }
        add(menu, "Refresh now", #selector(refreshNow), key: "r")
        add(menu, "Copy status", #selector(copyStatus), key: "")
        if dual {
            let pages = NSMenuItem(title: "Open usage page", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (title, sel) in [("Claude", #selector(openUsage)), ("Codex", #selector(openCodexUsage))] {
                let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
                it.target = self
                sub.addItem(it)
            }
            pages.submenu = sub
            menu.addItem(pages)
        } else {
            add(menu, "Open usage page", #selector(openUsage), key: "")
        }
        menu.addItem(.separator())
        addCheck(menu, "Animations", #selector(toggleAnimations), on: animationsEnabled)
        addCheck(menu, "Compact (session only)", #selector(toggleCompact), on: compactEnabled)
        // Which providers reach the menu bar. Pointless with only one, so it appears only
        // once Codex is readable.
        if dual {
            let barItem = NSMenuItem(title: "Menu bar", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for m in BarMode.allCases {
                let it = NSMenuItem(title: m.title, action: #selector(setBarModeOption(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = m.rawValue
                it.state = (barMode == m) ? .on : .off
                sub.addItem(it)
            }
            barItem.submenu = sub
            menu.addItem(barItem)
        }
        // How the trend chart is drawn. The two-provider layouts are offered only when there
        // is a second provider to draw.
        let chartItem = NSMenuItem(title: "Trend chart", action: nil, keyEquivalent: "")
        let chartSub = NSMenu()
        // With one provider the two-provider layouts all reduce to the same picture, so only
        // "Claude only" and "Off" are listed — and any non-off mode reads as "Claude only".
        let checked: ChartMode = dual ? chartMode : (chartMode == .off ? .off : .claudeOnly)
        for m in ChartMode.allCases {
            if !dual, m == .stacked || m == .overlay || m == .codexOnly { continue }
            let it = NSMenuItem(title: m.title, action: #selector(setChartModeOption(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = m.rawValue
            it.state = (checked == m) ? .on : .off
            chartSub.addItem(it)
        }
        chartItem.submenu = chartSub
        menu.addItem(chartItem)
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

    /// One provider's chart series, or nil until there are enough samples to draw a line.
    /// The window is taken from the reading (Codex reports its own length) so the x-axis spans
    /// exactly the session it belongs to.
    private func seriesFor(_ p: Provider) -> ChartSeries? {
        let h = (p == .claude) ? history : codexHistory
        guard h.points.count >= 2 else { return nil }
        let u = (p == .claude) ? lastGood : codexLastGood
        let end = h.windowEpoch ?? 0                        // session end (reset time)
        return ChartSeries(points: h.points,
                           windowStart: end - sessionWindowSeconds(u), windowEnd: end,
                           color: providerColor(p),
                           label: p.title)
    }

    /// Providers to chart right now: the mode's choice, minus a signed-out Claude (recording
    /// has stopped, so its chart would be a frozen picture of a past window) and minus
    /// anything without enough samples yet.
    private func chartable() -> [(Provider, ChartSeries)] {
        var provs = chartProviders(chartMode, codexAvailable: codexUsage() != nil)
        if lastGood.map(isLoggedOut) ?? false { provs.removeAll { $0 == .claude } }
        return provs.compactMap { p in seriesFor(p).map { (p, $0) } }
    }

    // Session usage trend chart(s) for this window, at the top of the dropdown.
    private func addCharts(to menu: NSMenu) {
        let items = chartable()
        guard !items.isEmpty else { return }
        let header = NSMenuItem(title: "Session trend (this window)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let click: () -> Void = { [weak self] in self?.showLargeChart() }
        if chartMode == .overlay && items.count > 1 {
            let it = NSMenuItem()
            it.view = SparkChartView(series: items.map { $0.1 },
                                     frame: NSRect(x: 0, y: 0, width: 240, height: 96), onClick: click)
            menu.addItem(it)
        } else {
            // Stacked: one chart per provider, each labeled inside its own plot. A lone chart
            // needs no label at all.
            for (p, series) in items {
                let it = NSMenuItem()
                it.view = SparkChartView(series: [series], title: items.count > 1 ? p.title : nil,
                                         frame: NSRect(x: 0, y: 0, width: 240, height: items.count > 1 ? 96 : 82),
                                         onClick: click)
                menu.addItem(it)
            }
        }
        add(menu, "Enlarge graph", #selector(showLargeChart), key: "")
        menu.addItem(.separator())
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
    // Kick a background collection for every installed collector; refresh the display as each
    // finishes. The Codex collector is absent on an installation that predates it, and exits
    // immediately when the Codex CLI isn't installed, so it's safe to fire unconditionally.
    private func runCollect() {
        for path in [collectPath, codexCollectPath] where FileManager.default.isExecutableFile(atPath: path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
            try? p.run()
        }
    }
    @objc private func systemDidWake() {
        refresh()                 // show the cached values immediately
        runCollect()              // fetch fresh (launchd can lag right after wake)
        // The network may still be coming up — one delayed retry.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.runCollect() }
    }
    @objc private func openUsage() {
        if let url = URL(string: claudeUsageURL) { NSWorkspace.shared.open(url) }
    }
    @objc private func openCodexUsage() {
        if let url = URL(string: codexUsageURL) { NSWorkspace.shared.open(url) }
    }
    // Signing in is interactive, so hand it to Terminal. Generating a .command file and
    // launching it with `open` needs no AppleEvents permission (same approach as
    // update.command); scripting Terminal directly would trigger an automation prompt.
    @objc private func signIn() {
        let script = """
        #!/bin/bash
        echo "Signing in to Claude Code — follow the prompts below."
        echo
        "\(claudeBinaryPath())" auth login
        code=$?
        echo
        if [ $code -eq 0 ]; then
          echo "Signed in. The menu bar picks it up within a minute."
        else
          echo "Sign-in did not complete (exit $code)."
        fi
        echo "You can close this window."
        """
        let url = URL(fileURLWithPath: NSString(string: "~/.claude-usage/signin.command").expandingTildeInPath)
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [url.path]
        try? p.run()
        // Sign-in takes a browser round trip; re-collect a few times so the menu bar recovers
        // without waiting for the next launchd tick.
        for delay in [20.0, 45.0, 90.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.runCollect() }
        }
    }
    // Where the claude CLI lives; mirrors the collector's fallback order.
    private func claudeBinaryPath() -> String {
        let fm = FileManager.default
        let candidates = [NSString(string: "~/.local/bin/claude").expandingTildeInPath,
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.first { fm.isExecutableFile(atPath: $0) } ?? "claude"
    }
    // Copies exactly what the menu bar shows, so a pasted status always matches the screen.
    @objc private func copyStatus() {
        guard lastGood != nil || codexUsage() != nil else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(barText(currentRender()), forType: .string)
    }
    @objc private func setAlertOption(_ sender: NSMenuItem) {
        if sender.tag == 0 {
            alertsEnabled = false
        } else {
            alertsEnabled = true
            alertThreshold = sender.tag
            alerted.removeAll()
            requestNotificationAuth()
        }
        UserDefaults.standard.set(alertsEnabled, forKey: "usageAlerts")
        UserDefaults.standard.set(alertThreshold, forKey: "alertThreshold")
        rebuildMenu()
    }
    @objc private func toggleCompact() {
        compactEnabled.toggle()
        UserDefaults.standard.set(compactEnabled, forKey: "compactMode")
        updateStatusItem()
        rebuildMenu()
    }
    @objc private func setBarModeOption(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = BarMode(rawValue: raw) else { return }
        barMode = m
        UserDefaults.standard.set(raw, forKey: "barMode")
        updateStatusItem()
        rebuildMenu()
    }
    @objc private func setChartModeOption(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = ChartMode(rawValue: raw) else { return }
        chartMode = m
        UserDefaults.standard.set(raw, forKey: "chartMode")
        rebuildMenu()
    }
    @objc private func openAbout() {
        if let url = URL(string: repoURL) { NSWorkspace.shared.open(url) }
    }
    // Enlarge the trend chart into a reusable floating window.
    // Enlarge the trend chart into a reusable floating window, following the same mode as the
    // dropdown: overlaid in one plot, or stacked one plot per provider.
    @objc private func showLargeChart() {
        let items = chartable()
        guard !items.isEmpty else { return }
        let overlay = (chartMode == .overlay) || items.count == 1
        let each = NSSize(width: 620, height: 360)
        let size = overlay ? each : NSSize(width: each.width, height: each.height * CGFloat(items.count))
        let content: NSView
        if overlay {
            content = SparkChartView(series: items.map { $0.1 },
                                     title: items.count > 1 ? nil : items[0].0.title,
                                     frame: NSRect(origin: .zero, size: size))
        } else {
            let stack = NSView(frame: NSRect(origin: .zero, size: size))
            for (i, item) in items.enumerated() {
                // Top-down: the first provider takes the top slot.
                let y = size.height - each.height * CGFloat(i + 1)
                stack.addSubview(SparkChartView(series: [item.1], title: item.0.title,
                                                frame: NSRect(x: 0, y: y, width: each.width, height: each.height)))
            }
            content = stack
        }
        let win: NSWindow
        if let w = chartWindow {
            win = w
        } else {
            win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            win.level = .floating
            chartWindow = win
        }
        win.title = items.map { $0.0.title }.joined(separator: " + ") + " — Session usage (this window)"
        win.setContentSize(size)
        win.contentView = content
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
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
        rebuildMenu()
    }
    @objc private func toggleAnimations() {
        animationsEnabled.toggle()
        UserDefaults.standard.set(animationsEnabled, forKey: "animationsEnabled")
        if !animationsEnabled { stopSpinner() }
        updateStatusItem()
        rebuildMenu()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
