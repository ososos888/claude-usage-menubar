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

    private func remaining(_ epoch: Double?, short: Bool) -> String? {
        guard let e = epoch else { return nil }
        let diff = Int(e - Date().timeIntervalSince1970)
        if diff <= 0 { return short ? "0m" : "resets soon" }
        let d = diff / 86400, h = (diff % 86400) / 3600, m = (diff % 3600) / 60
        if short {
            if d > 0 { return "\(d)d\(h)h" }
            if h > 0 { return "\(h)h\(m)m" }
            return "\(m)m"
        } else {
            if d > 0 { return "\(d)d \(h)h left" }
            if h > 0 { return "\(h)h \(m)m left" }
            return "\(m)m left"
        }
    }

    private func color(forPct p: Int?) -> NSColor? {
        guard let p = p else { return nil }
        if p >= 90 { return .systemRed }
        if p >= 70 { return .systemOrange }
        return nil
    }

    // MARK: - Render
    private func refresh() {
        guard let u = load() else {
            setTitle("Claude --", color: .systemRed)
            rebuildMenu(nil)
            return
        }
        let s = u.sessionPct.map(String.init) ?? "?"
        let w = u.weeklyPct.map(String.init) ?? "?"
        var title = "s\(s)% · w\(w)%"  // s = session (5-hour rolling), w = weekly
        if let rem = remaining(u.sessionEpoch, short: true) { title += " · ⏳\(rem)" }
        setTitle(title, color: color(forPct: u.sessionPct))
        rebuildMenu(u)
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
            let sRem = remaining(u.sessionEpoch, short: false) ?? "resets \(u.sessionReset ?? "?")"
            info("Session: \(s)% used · \(sRem)")
            let w = u.weeklyPct.map(String.init) ?? "?"
            let wRem = remaining(u.weeklyEpoch, short: false) ?? "resets \(u.weeklyReset ?? "?")"
            info("Weekly (all models): \(w)% used · \(wRem)")
            if let ml = u.modelLabel, let mp = u.modelPct { info("Weekly (\(ml)): \(mp)%") }
            menu.addItem(.separator())
            info("Updated: \(u.collectedAt ?? "?")")
        } else {
            info("No data (daemon not running?)")
        }
        add(menu, "Refresh now", #selector(refreshNow), key: "r")
        add(menu, "Open usage page", #selector(openUsage), key: "")
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
        let p = Process()
        p.executableURL = URL(fileURLWithPath: collectPath)
        p.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
        try? p.run()
    }
    @objc private func openUsage() {
        if let url = URL(string: "https://claude.ai/settings/usage") { NSWorkspace.shared.open(url) }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // Menu-bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
