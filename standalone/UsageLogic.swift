// Pure, UI-free logic for ClaudeUsageBar — kept separate so it can be unit-tested with
// plain swiftc (see ../tests/run.sh). No AppKit here.
import Foundation

// The two subscriptions this widget can track. Claude is the primary one; Codex is optional
// and simply absent when its CLI isn't installed or nobody is signed in.
enum Provider: String, Codable, CaseIterable {
    case claude, codex
    /// Full name, for the dropdown and notifications.
    var title: String { self == .claude ? "Claude" : "Codex" }
    /// One-letter menu bar tag, used only when both providers are shown side by side.
    var tag: String { self == .claude ? "C" : "X" }
}

// Parsed contents of ~/.claude-usage/usage.json (collect.sh, Claude) or
// ~/.claude-usage/codex-usage.json (collect-codex.sh, Codex). Both collectors write the same
// key names for the fields they share, so one struct covers both; the extras are per-provider
// and stay nil for the other (`modelLabel`/`modelPct` are Claude-only, `plan`/`resetCredits`
// and the window lengths are Codex-only).
struct Usage: Equatable {
    var sessionPct: Int?
    var sessionReset: String?
    var sessionEpoch: Double?
    var weeklyPct: Int?
    var weeklyReset: String?
    var weeklyEpoch: Double?
    var modelLabel: String?
    var modelPct: Int?
    var plan: String?              // Codex plan name, e.g. "plus"
    var resetCredits: Int?         // Codex rate-limit reset credits available
    var sessionWindowMins: Int?    // measured session window length (Codex reports it)
    var weeklyWindowMins: Int?
    var error: String?
    var collectedAt: String?
    var checkedAt: String?

    /// Parse raw JSON bytes; nil only if the bytes aren't a JSON object.
    static func parse(_ data: Data) -> Usage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(obj)
    }
    static func parse(_ obj: [String: Any]) -> Usage {
        func int(_ k: String) -> Int? { (obj[k] as? Int) ?? (obj[k] as? Double).map { Int($0) } }
        func str(_ k: String) -> String? { obj[k] as? String }
        func dbl(_ k: String) -> Double? { (obj[k] as? Double) ?? (obj[k] as? Int).map { Double($0) } }
        var u = Usage()
        u.sessionPct = int("session_pct"); u.sessionReset = str("session_reset"); u.sessionEpoch = dbl("session_reset_epoch")
        u.weeklyPct = int("weekly_all_pct"); u.weeklyReset = str("weekly_all_reset"); u.weeklyEpoch = dbl("weekly_all_reset_epoch")
        u.modelLabel = str("weekly_model_label"); u.modelPct = int("weekly_model_pct")
        u.plan = str("plan"); u.resetCredits = int("reset_credits")
        u.sessionWindowMins = int("session_window_mins"); u.weeklyWindowMins = int("weekly_window_mins")
        u.error = str("error"); u.collectedAt = str("collected_at"); u.checkedAt = str("checked_at")
        return u
    }
}

// Severity used to color a menu bar item; mapped to a concrete NSColor in the view layer.
// `dim` is not a severity but a de-emphasis: provider tags, separators, and values we can no
// longer refresh.
enum UsageLevel { case normal, warn, critical, dim }

let usageImminentSeconds = 15 * 60

/// Color level for a percentage: 80%+ critical, 60%+ warn.
func level(forPct p: Int?) -> UsageLevel {
    guard let p = p else { return .normal }
    if p >= 80 { return .critical }
    if p >= 60 { return .warn }
    return .normal
}

/// Color level for time-left: red within 15 min of reset, orange within 60 min.
/// (The reset window itself, diff <= 30s, is handled elsewhere → normal.)
func timeLevel(epoch: Double?, now: Date = Date()) -> UsageLevel {
    guard let e = epoch else { return .normal }
    let diff = Int(e - now.timeIntervalSince1970)
    if diff <= 30 { return .normal }
    if diff <= usageImminentSeconds { return .critical }
    if diff <= 60 * 60 { return .warn }
    return .normal
}

struct Remain: Equatable { let text: String; let resetting: Bool }

/// Human-readable time until reset. `resetting` is true during the brief reset window
/// (just elapsed, about to elapse, or an implausibly large mid-reset value).
func remainingTime(epoch: Double?, maxSeconds: Int, short: Bool, now: Date = Date()) -> Remain? {
    guard let e = epoch else { return nil }
    let diff = Int(e - now.timeIntervalSince1970)
    if diff <= 30 || diff > maxSeconds {
        return Remain(text: short ? "resetting" : "resetting…", resetting: true)
    }
    let d = diff / 86400, h = (diff % 86400) / 3600, m = (diff % 3600) / 60
    let text: String
    if short {
        if d > 0 { text = "\(d)d\(h)h" } else if h > 0 { text = "\(h)h\(m)m" } else { text = "\(m)m" }
    } else {
        if d > 0 { text = "\(d)d \(h)h left" } else if h > 0 { text = "\(h)h \(m)m left" } else { text = "\(m)m left" }
    }
    return Remain(text: text, resetting: false)
}

/// Semantic version compare: -1 if a<b, 0 if equal, 1 if a>b.
func compareVersions(_ a: String, _ b: String) -> Int {
    let pa = a.split(separator: ".").map { Int($0) ?? 0 }
    let pb = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0 ..< max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
        if x != y { return x < y ? -1 : 1 }
    }
    return 0
}

/// Whether to adopt a freshly-read reading or ignore it as an oscillation back to an
/// already-expired window. Around a reset, `/usage` flips between the just-reset old window
/// and the new one; once we've locked onto the later (new) window, a reading whose session
/// reset time jumps more than `thresholdSeconds` *earlier* is a stale old-window flip.
/// (Normal drift is only minutes, so it's always adopted.)
func shouldAdopt(newEpoch: Double?, lastEpoch: Double?, thresholdSeconds: Double = 2 * 3600) -> Bool {
    guard let ne = newEpoch, let oe = lastEpoch else { return true }
    return !(oe - ne > thresholdSeconds)
}

// A recorded session-usage sample and the rolling history for the current session window.
struct HistoryPoint: Equatable, Codable { let t: Double; let pct: Int }
struct SessionHistory: Equatable, Codable {
    var windowEpoch: Double?    // the session reset epoch this history belongs to
    var points: [HistoryPoint]
}

/// Append a sample to the session history, resetting it when a new session window begins.
///   - a new window (reset time jumps > 1h forward) clears the points
///   - samples are throttled to ~one per `minInterval` seconds
///   - the history is capped at `maxPoints`
func updatedHistory(_ h: SessionHistory, sessionEpoch: Double?, pct: Int?, now: Double,
                    windowSeconds: Double = 5 * 3600, minInterval: Double = 50, maxPoints: Int = 600) -> SessionHistory {
    var out = h
    if let se = sessionEpoch {
        let isNew = (out.windowEpoch == nil) || (se - out.windowEpoch! > 3600)  // new window (reset)
        out.windowEpoch = se
        if isNew { out.points = [] }   // wipe on reset; record only what we actually measure
    }
    guard let p = pct else { return out }
    if let last = out.points.last, now - last.t < minInterval { return out }
    // Cumulative-since-reset view: usage never decreases within a window. A rolling-window
    // roll-off or /usage noise is held at the running peak; it resets to 0 on a new window.
    let cumulative = max(p, out.points.last?.pct ?? p)
    out.points.append(HistoryPoint(t: now, pct: cumulative))
    // Drop anything older than the current window — leftover garbage if a reset was ever
    // missed (app not running at reset, etc.). Keyed on `now`, not the drifting reset time.
    let cutoff = now - windowSeconds - 600
    out.points.removeAll { $0.t < cutoff }
    if out.points.count > maxPoints { out.points.removeFirst(out.points.count - maxPoints) }
    return out
}

private let staleISOFormatter = ISO8601DateFormatter()

/// True if an ISO-8601 timestamp is older than `seconds`. Unparsable/missing → false.
func isOlderThan(_ iso: String?, seconds: Double, now: Date = Date()) -> Bool {
    guard let s = iso, let d = staleISOFormatter.date(from: s) else { return false }
    return now.timeIntervalSince1970 - d.timeIntervalSince1970 > seconds
}

/// True if the collector's `checked_at` timestamp is older than `staleSeconds`, i.e. the
/// daemon isn't even running. Note a *failing* collector still refreshes `checked_at` —
/// use `isDataUntrusted` to ask whether the values themselves are still believable.
func isStale(checkedAt: String?, now: Date = Date(), staleSeconds: Double = 180) -> Bool {
    isOlderThan(checkedAt, seconds: staleSeconds, now: now)
}

/// `error` values collect.sh writes when the CLI has no usable credentials. Both are fixed
/// by signing in again, so the app treats them the same way.
let loggedOutErrors: Set<String> = ["logged_out", "auth_expired"]

/// Claude Code is signed out (or its token expired): usage can't be read at all.
func isLoggedOut(_ u: Usage) -> Bool {
    guard let e = u.error else { return false }
    return loggedOutErrors.contains(e)
}

/// Whether the cached values must no longer be presented as live. Keyed on `collected_at`
/// (last *successful* collection) rather than `checked_at`, because a failing run keeps
/// bumping `checked_at` — which is why a signed-out Mac used to keep showing stale numbers
/// as if nothing were wrong.
func isDataUntrusted(_ u: Usage, now: Date = Date(), staleSeconds: Double = 180) -> Bool {
    if u.error != nil { return true }
    return isOlderThan(u.collectedAt, seconds: staleSeconds, now: now)
}

/// Whether to show the brief reset animation. A reset is only believable while collection
/// is actually succeeding: a frozen reset epoch from a failing collector (signed out, say)
/// elapses on its own and would otherwise spin the hourglass forever.
func showResetting(_ u: Usage, maxSeconds: Int, now: Date = Date()) -> Bool {
    guard !isDataUntrusted(u, now: now) else { return false }
    return remainingTime(epoch: u.sessionEpoch, maxSeconds: maxSeconds, short: true, now: now)?.resetting ?? false
}

/// One-shot gate for the signed-out notification: fires on the transition into the
/// signed-out state and re-arms only once usage is readable again. Reset notifications have
/// misfired repeatedly in this app's history, so this guard is explicit and unit-tested.
func shouldNotifyLogout(loggedOut: Bool, alreadyNotified: inout Bool) -> Bool {
    guard loggedOut else { alreadyNotified = false; return false }
    if alreadyNotified { return false }
    alreadyNotified = true
    return true
}

// MARK: - Provider availability and window lengths

/// Codex reported no usage we can show. Codex is optional, so these states hide the Codex
/// half of the widget entirely instead of nagging about a product the user may not use.
let codexAbsentErrors: Set<String> = ["not_installed", "logged_out"]

/// Whether a Codex reading is worth putting on screen: the collector found the CLI, somebody
/// is signed in, and at least one percentage has been read at some point.
func isCodexAvailable(_ u: Usage?) -> Bool {
    guard let u = u else { return false }
    if let e = u.error, codexAbsentErrors.contains(e) { return false }
    return u.sessionPct != nil || u.weeklyPct != nil
}

/// Length of the session window in seconds. Claude's is a fixed 5 hours; Codex reports its
/// own (`windowDurationMins`, 300 today) so a future change doesn't silently skew the chart.
func sessionWindowSeconds(_ u: Usage?, fallback: Double = 5 * 3600) -> Double {
    guard let m = u?.sessionWindowMins, m > 0 else { return fallback }
    return Double(m) * 60
}

/// Largest remaining time still believable for a weekly window: 7 days plus a day of slack.
/// Anything above it is a mid-reset parse artifact, not a real reading.
let weeklyMaxSeconds = 8 * 86400

/// Largest remaining time still believable for a session window: the window plus an hour of
/// slack. Anything above it is a mid-reset parse artifact, not a real reading.
func sessionMaxSeconds(_ u: Usage?, fallback: Int = 6 * 3600) -> Int {
    guard let m = u?.sessionWindowMins, m > 0 else { return fallback }
    return m * 60 + 3600
}

// MARK: - Display options (persisted in UserDefaults by the app)

/// Which providers the menu bar itself shows. The dropdown always lists everything available.
enum BarMode: String, CaseIterable {
    case both, claudeOnly, codexOnly
    var title: String {
        switch self {
        case .both: return "Claude + Codex"
        case .claudeOnly: return "Claude only"
        case .codexOnly: return "Codex only"
        }
    }
}

/// How the session trend chart(s) are drawn in the dropdown.
enum ChartMode: String, CaseIterable {
    case stacked, overlay, claudeOnly, codexOnly, off
    var title: String {
        switch self {
        case .stacked: return "Two charts (stacked)"
        case .overlay: return "One chart (overlaid)"
        case .claudeOnly: return "Claude only"
        case .codexOnly: return "Codex only"
        case .off: return "Off"
        }
    }
}

/// Providers to chart, in draw order, given the mode and what data exists.
func chartProviders(_ mode: ChartMode, codexAvailable: Bool) -> [Provider] {
    switch mode {
    case .off: return []
    case .claudeOnly: return [.claude]
    case .codexOnly: return codexAvailable ? [.codex] : [.claude]
    case .stacked, .overlay: return codexAvailable ? [.claude, .codex] : [.claude]
    }
}

// MARK: - Menu bar rendering

/// A drawn hourglass standing in for a run of text: sand level = `remaining` of `windowHours`.
struct HourglassSpec: Equatable { let remaining: Int; let windowHours: Int }

/// One colored run of menu bar text. When `hourglass` is set the view draws that icon instead
/// of the text, and `text` is the plain-text stand-in used for "Copy status" and VoiceOver.
struct Seg: Equatable {
    let text: String
    let level: UsageLevel
    var hourglass: HourglassSpec?
    init(text: String, level: UsageLevel, hourglass: HourglassSpec? = nil) {
        self.text = text; self.level = level; self.hourglass = hourglass
    }
}

/// What the status item's image should be. The item has exactly one image slot, so the drawn
/// hourglass can only stand for one session window — it is therefore used only when a single
/// provider is on the bar, and both providers fall back to a plain ⏳ glyph.
/// `hourglass(remainingSeconds, windowHours)` — the sand level needs both the time left and
/// the length of the window it is measured against.
enum BarIcon: Equatable { case none, hourglass(Int, Int), spinner }

struct BarRender: Equatable { let segments: [Seg]; let icon: BarIcon }

/// Menu bar text for a single provider — the historical format: `s14% · w25% · ⏳3h58m`.
private func singleBar(_ u: Usage?, compact: Bool, animations: Bool, now: Date) -> BarRender {
    guard let u = u else { return BarRender(segments: [Seg(text: "Claude --", level: .critical)], icon: .none) }
    // Signed out: the numbers are unknowable until the user signs in, so make the bar itself
    // the call to action instead of showing figures we can no longer refresh.
    if isLoggedOut(u) { return BarRender(segments: [Seg(text: "⚠ Sign in", level: .critical)], icon: .none) }
    let s = u.sessionPct.map(String.init) ?? "?"
    let w = u.weeklyPct.map(String.init) ?? "?"
    // Otherwise untrusted (collector stopped or failing): dim and mark, don't imply the old
    // numbers are live.
    if isDataUntrusted(u, now: now) {
        let body = compact ? "⚠ s\(s)%" : "⚠ s\(s)% · w\(w)%"
        return BarRender(segments: [Seg(text: body, level: .dim)], icon: .none)
    }
    let maxSecs = sessionMaxSeconds(u)
    var segs: [Seg] = [Seg(text: "s\(s)%", level: level(forPct: u.sessionPct))]
    if !compact {
        segs.append(Seg(text: " · ", level: .normal))
        segs.append(Seg(text: "w\(w)%", level: level(forPct: u.weeklyPct)))
    }
    guard let r = remainingTime(epoch: u.sessionEpoch, maxSeconds: maxSecs, short: true, now: now) else {
        return BarRender(segments: segs, icon: .none)
    }
    if r.resetting {
        segs.append(Seg(text: animations ? " · resetting" : " · ↻ resetting", level: .normal))
        return BarRender(segments: segs, icon: animations ? .spinner : .none)
    }
    let timeLvl = timeLevel(epoch: u.sessionEpoch, now: now)
    if animations, let epoch = u.sessionEpoch {
        segs.append(Seg(text: " · ", level: .normal))
        segs.append(Seg(text: r.text, level: timeLvl))
        let windowHours = max(1, Int((sessionWindowSeconds(u) / 3600).rounded()))
        return BarRender(segments: segs, icon: .hourglass(Int(epoch - now.timeIntervalSince1970), windowHours))
    }
    segs.append(Seg(text: " · ⏳", level: .normal))
    segs.append(Seg(text: r.text, level: timeLvl))
    return BarRender(segments: segs, icon: .none)
}

/// One provider's share of a two-provider menu bar: `C 14% ⏳3h58m`. Weekly is dropped here —
/// four percentages plus two clocks is more width than a menu bar should take, so weekly
/// lives in the dropdown and the tooltip.
private func dualPart(_ p: Provider, _ u: Usage?, compact: Bool, animations: Bool, now: Date) -> [Seg] {
    let tag = Seg(text: "\(p.tag) ", level: .dim)
    guard let u = u else { return [tag, Seg(text: "--", level: .critical)] }
    if isLoggedOut(u) { return [tag, Seg(text: "⚠", level: .critical)] }
    let pct = u.sessionPct.map { "\($0)%" } ?? "?%"
    if isDataUntrusted(u, now: now) { return [tag, Seg(text: "⚠\(pct)", level: .dim)] }
    var segs = [tag, Seg(text: pct, level: level(forPct: u.sessionPct))]
    guard !compact else { return segs }
    guard let r = remainingTime(epoch: u.sessionEpoch, maxSeconds: sessionMaxSeconds(u), short: true, now: now)
    else { return segs }
    if r.resetting {
        segs.append(Seg(text: " ↻", level: .normal))
    } else {
        // With animations on this run is drawn as the same minimal hourglass the
        // single-provider bar puts in the image slot, inline this time so both providers can
        // have one. Off, it stays the plain ⏳ glyph.
        let hg = animations ? u.sessionEpoch.map {
            HourglassSpec(remaining: Int($0 - now.timeIntervalSince1970),
                          windowHours: max(1, Int((sessionWindowSeconds(u) / 3600).rounded())))
        } : nil
        segs.append(Seg(text: " ⏳", level: .normal, hourglass: hg))
        segs.append(Seg(text: r.text, level: timeLevel(epoch: u.sessionEpoch, now: now)))
    }
    return segs
}

/// The complete menu bar for the current readings and options.
///   - one provider  → the historical format, drawn hourglass and reset spinner included
///   - two providers → `C 14% ⏳3h58m · X 83% ⏳2h47m`, text glyphs only (one image slot)
/// A `codexOnly` bar falls back to Claude when Codex has nothing to show, so the bar is
/// never blank just because the second CLI isn't signed in.
func menuBarRender(claude: Usage?, codex: Usage?, mode: BarMode, compact: Bool,
                   animations: Bool, now: Date = Date()) -> BarRender {
    let codexOK = isCodexAvailable(codex)
    switch mode {
    case .claudeOnly:
        return singleBar(claude, compact: compact, animations: animations, now: now)
    case .codexOnly:
        guard codexOK else { return singleBar(claude, compact: compact, animations: animations, now: now) }
        return singleBar(codex, compact: compact, animations: animations, now: now)
    case .both:
        guard codexOK else { return singleBar(claude, compact: compact, animations: animations, now: now) }
        var segs = dualPart(.claude, claude, compact: compact, animations: animations, now: now)
        segs.append(Seg(text: " · ", level: .dim))
        segs.append(contentsOf: dualPart(.codex, codex, compact: compact, animations: animations, now: now))
        return BarRender(segments: segs, icon: .none)
    }
}

/// Plain-text version of a rendered bar — used for "Copy status".
func barText(_ r: BarRender) -> String { r.segments.map { $0.text }.joined() }

// MARK: - Dropdown / tooltip text

/// The detail lines for one provider, as they appear in the dropdown and the tooltip.
/// Nil-safe and source-agnostic: it reads whichever fields the provider's collector filled in.
func detailLines(_ p: Provider, _ u: Usage, now: Date = Date()) -> [String] {
    // No provider name here: the caller adds one when there are two providers to tell apart.
    if isLoggedOut(u) { return ["Signed out — usage tracking is paused"] }
    var lines: [String] = []
    let sMax = sessionMaxSeconds(u), wMax = weeklyMaxSeconds
    let s = u.sessionPct.map(String.init) ?? "?"
    let sRem = remainingTime(epoch: u.sessionEpoch, maxSeconds: sMax, short: false, now: now)?.text
        ?? u.sessionReset.map { "resets \($0)" } ?? "reset time unknown"
    lines.append("Session: \(s)% used · \(sRem)")
    let w = u.weeklyPct.map(String.init) ?? "?"
    let wRem = remainingTime(epoch: u.weeklyEpoch, maxSeconds: wMax, short: false, now: now)?.text
        ?? u.weeklyReset.map { "resets \($0)" } ?? "reset time unknown"
    lines.append(p == .claude ? "Weekly (all models): \(w)% used · \(wRem)"
                              : "Weekly: \(w)% used · \(wRem)")
    if let ml = u.modelLabel, let mp = u.modelPct { lines.append("Weekly (\(ml)): \(mp)%") }
    if let plan = u.plan {
        var line = "Plan: \(plan)"
        if let c = u.resetCredits, c > 0 { line += " · \(c) rate-limit reset\(c == 1 ? "" : "s") available" }
        lines.append(line)
    }
    return lines
}

/// Hover text for the status item: every available provider, then freshness.
func tooltipText(claude: Usage?, codex: Usage?, now: Date = Date()) -> String {
    var lines: [String] = []
    let showCodex = isCodexAvailable(codex)
    func block(_ p: Provider, _ u: Usage) {
        // Prefix each line with the provider only when there are two blocks to tell apart.
        let body = detailLines(p, u, now: now)
        lines.append(contentsOf: showCodex ? body.map { "\(p.title) · \($0)" } : body)
        if let ca = u.collectedAt, !showCodex { lines.append("Updated: \(ca)") }
        if isStale(checkedAt: u.checkedAt, now: now) {
            lines.append("⚠ \(p.title): data may be stale — the collector daemon may have stopped.")
        } else if isDataUntrusted(u, now: now), !isLoggedOut(u) {
            lines.append("⚠ \(p.title): not updating — the last collection failed\(u.error.map { " (\($0))" } ?? "").")
        }
    }
    if let c = claude {
        if isLoggedOut(c), !showCodex {
            return "Claude Code is signed out — usage tracking is paused.\n"
                 + "Click the menu bar item and choose \"Sign in to Claude…\"."
        }
        block(.claude, c)
    } else {
        lines.append("Claude: no data (daemon not running?)")
    }
    if showCodex, let x = codex { block(.codex, x) }
    return lines.joined(separator: "\n")
}
