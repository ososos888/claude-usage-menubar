// Unit tests for the pure logic in ../standalone/UsageLogic.swift.
// Compiled and run by run.sh (plain swiftc, no XCTest/SPM). Exits non-zero on failure.
import Foundation

var total = 0, failed = 0
func check(_ cond: Bool, _ name: String) {
    total += 1
    if cond { print("  ok   \(name)") } else { failed += 1; print("  FAIL \(name)") }
}

let now = Date(timeIntervalSince1970: 1_000_000)      // fixed "now" for deterministic tests
let H = 3600.0, D = 86400.0
let sessionMax = 6 * 3600, weeklyMax = 8 * 86400

// MARK: remainingTime
check(remainingTime(epoch: nil, maxSeconds: sessionMax, short: true, now: now) == nil, "remaining: nil epoch → nil")
check(remainingTime(epoch: now.timeIntervalSince1970 + H, maxSeconds: sessionMax, short: true, now: now)
        == Remain(text: "1:00", resetting: false), "remaining: 1h short")
check(remainingTime(epoch: now.timeIntervalSince1970 + H, maxSeconds: sessionMax, short: false, now: now)
        == Remain(text: "1h 0m left", resetting: false), "remaining: 1h long")
check(remainingTime(epoch: now.timeIntervalSince1970 + 3 * D + 2 * H, maxSeconds: weeklyMax, short: true, now: now)
        == Remain(text: "3d2h", resetting: false), "remaining: 3d2h short (days keep their unit)")
check(remainingTime(epoch: now.timeIntervalSince1970 + 300, maxSeconds: sessionMax, short: false, now: now)
        == Remain(text: "5m left", resetting: false), "remaining: 5m long")
check(remainingTime(epoch: now.timeIntervalSince1970 + 300, maxSeconds: sessionMax, short: true, now: now)
        == Remain(text: "0:05", resetting: false), "remaining: under an hour still reads as a clock")
check(remainingTime(epoch: now.timeIntervalSince1970 + 4 * H + 8 * 60, maxSeconds: sessionMax, short: true, now: now)
        == Remain(text: "4:08", resetting: false), "remaining: minutes are zero-padded")
check(remainingTime(epoch: now.timeIntervalSince1970 + 20, maxSeconds: sessionMax, short: true, now: now)?.resetting == true,
      "remaining: <=30s → resetting")
check(remainingTime(epoch: now.timeIntervalSince1970 - 100, maxSeconds: sessionMax, short: true, now: now)?.resetting == true,
      "remaining: past → resetting")
check(remainingTime(epoch: now.timeIntervalSince1970 + 7 * H, maxSeconds: sessionMax, short: true, now: now)?.resetting == true,
      "remaining: > maxSeconds (mid-reset artifact) → resetting")

// MARK: level(forPct:)
check(level(forPct: nil) == .normal, "level: nil → normal")
check(level(forPct: 59) == .normal, "level: 59 → normal")
check(level(forPct: 60) == .warn, "level: 60 → warn")
check(level(forPct: 79) == .warn, "level: 79 → warn")
check(level(forPct: 80) == .critical, "level: 80 → critical")
check(level(forPct: 100) == .critical, "level: 100 → critical")

// MARK: timeLevel
check(timeLevel(epoch: nil, now: now) == .normal, "timeLevel: nil → normal")
check(timeLevel(epoch: now.timeIntervalSince1970 + 20, now: now) == .normal, "timeLevel: <=30s → normal (reset handled elsewhere)")
check(timeLevel(epoch: now.timeIntervalSince1970 + 10 * 60, now: now) == .critical, "timeLevel: 10m → critical")
check(timeLevel(epoch: now.timeIntervalSince1970 + 15 * 60, now: now) == .critical, "timeLevel: 15m → critical")
check(timeLevel(epoch: now.timeIntervalSince1970 + 30 * 60, now: now) == .warn, "timeLevel: 30m → warn")
check(timeLevel(epoch: now.timeIntervalSince1970 + 60 * 60, now: now) == .warn, "timeLevel: 60m → warn")
check(timeLevel(epoch: now.timeIntervalSince1970 + 2 * H, now: now) == .normal, "timeLevel: 2h → normal")

// MARK: compareVersions
check(compareVersions("1.2.3", "1.2.4") == -1, "version: 1.2.3 < 1.2.4")
check(compareVersions("1.2.3", "1.2.3") == 0, "version: equal")
check(compareVersions("1.3.0", "1.2.9") == 1, "version: 1.3.0 > 1.2.9")
check(compareVersions("1.2", "1.2.0") == 0, "version: 1.2 == 1.2.0")
check(compareVersions("2.0", "1.9.9") == 1, "version: 2.0 > 1.9.9")

// MARK: Usage.parse
let json = """
{"session_pct":6,"session_reset":"Jul 27 at 10:39pm (Asia/Seoul)","session_reset_epoch":1784727558,
 "weekly_all_pct":42,"weekly_all_reset":"Jul 30 at 4am","weekly_all_reset_epoch":1785000000,
 "weekly_model_label":"Fable","weekly_model_pct":0,"error":null,
 "collected_at":"2026-07-27T01:00:00Z","checked_at":"2026-07-27T01:00:00Z"}
"""
if let u = Usage.parse(Data(json.utf8)) {
    check(u.sessionPct == 6, "parse: sessionPct")
    check(u.sessionEpoch == 1784727558, "parse: sessionEpoch")
    check(u.weeklyPct == 42, "parse: weeklyPct")
    check(u.modelLabel == "Fable", "parse: modelLabel")
    check(u.modelPct == 0, "parse: modelPct")
    check(u.error == nil, "parse: null → nil")
} else {
    check(false, "parse: valid JSON should decode")
}
check(Usage.parse(Data("not json".utf8)) == nil, "parse: invalid bytes → nil")
check(Usage.parse(["session_pct": 6.0]).sessionPct == 6, "parse: double pct coerces to Int")
check(Usage.parse([:]).sessionPct == nil, "parse: empty dict → nil fields")

// MARK: isStale
let iso = ISO8601DateFormatter()
check(isStale(checkedAt: nil, now: now) == false, "stale: nil → false")
check(isStale(checkedAt: iso.string(from: now.addingTimeInterval(-60)), now: now) == false, "stale: 60s old → false")
check(isStale(checkedAt: iso.string(from: now.addingTimeInterval(-300)), now: now) == true, "stale: 300s old → true")

// MARK: signed-out / untrusted data handling
func usage(error: String? = nil, collectedAt: String? = nil, checkedAt: String? = nil,
           sessionEpoch: Double? = nil) -> Usage {
    var u = Usage()
    u.sessionPct = 20; u.weeklyPct = 3
    u.error = error; u.collectedAt = collectedAt; u.checkedAt = checkedAt
    u.sessionEpoch = sessionEpoch
    return u
}
let nowISO = iso.string(from: now)
let oldISO = iso.string(from: now.addingTimeInterval(-3600))

check(isLoggedOut(usage(error: "logged_out")) == true, "loggedOut: logged_out")
check(isLoggedOut(usage(error: "auth_expired")) == true, "loggedOut: auth_expired")
check(isLoggedOut(usage(error: "no_numbers")) == false, "loggedOut: other error → false")
check(isLoggedOut(usage()) == false, "loggedOut: no error → false")

check(isDataUntrusted(usage(collectedAt: nowISO, checkedAt: nowISO), now: now) == false,
      "untrusted: fresh success → false")
check(isDataUntrusted(usage(error: "logged_out", collectedAt: nowISO, checkedAt: nowISO), now: now) == true,
      "untrusted: error → true even when checked_at is fresh")
check(isDataUntrusted(usage(collectedAt: oldISO, checkedAt: nowISO), now: now) == true,
      "untrusted: old collected_at → true (a failing run keeps bumping checked_at)")
check(isDataUntrusted(usage(), now: now) == false, "untrusted: no timestamps → false")

// The bug this release fixes: signed out, the collector preserves an old reset epoch and keeps
// refreshing checked_at, so the elapsed epoch used to read as "resetting" forever.
let elapsed = now.timeIntervalSince1970 - 100
check(remainingTime(epoch: elapsed, maxSeconds: sessionMax, short: true, now: now)?.resetting == true,
      "resetting: elapsed epoch alone still says resetting")
check(showResetting(usage(error: "logged_out", collectedAt: oldISO, checkedAt: nowISO, sessionEpoch: elapsed),
                    maxSeconds: sessionMax, now: now) == false,
      "showResetting: signed out → never spins")
check(showResetting(usage(collectedAt: oldISO, checkedAt: nowISO, sessionEpoch: elapsed),
                    maxSeconds: sessionMax, now: now) == false,
      "showResetting: no recent successful collect → never spins")
check(showResetting(usage(collectedAt: nowISO, checkedAt: nowISO, sessionEpoch: elapsed),
                    maxSeconds: sessionMax, now: now) == true,
      "showResetting: fresh collect + elapsed epoch → real reset")
check(showResetting(usage(collectedAt: nowISO, checkedAt: nowISO,
                          sessionEpoch: now.timeIntervalSince1970 + 2 * H),
                    maxSeconds: sessionMax, now: now) == false,
      "showResetting: fresh collect, 2h left → not resetting")

// MARK: shouldNotifyLogout (one-shot per episode)
var notified = false
check(shouldNotifyLogout(loggedOut: true, alreadyNotified: &notified) == true, "logoutNotify: first time → fires")
check(shouldNotifyLogout(loggedOut: true, alreadyNotified: &notified) == false, "logoutNotify: still out → silent")
check(shouldNotifyLogout(loggedOut: true, alreadyNotified: &notified) == false, "logoutNotify: no repeats")
check(shouldNotifyLogout(loggedOut: false, alreadyNotified: &notified) == false, "logoutNotify: signed in → silent")
check(shouldNotifyLogout(loggedOut: true, alreadyNotified: &notified) == true, "logoutNotify: re-arms after recovery")

// MARK: shouldAdopt (reset-window oscillation guard)
check(shouldAdopt(newEpoch: nil, lastEpoch: 100_000) == true, "adopt: nil new → true")
check(shouldAdopt(newEpoch: 100_000, lastEpoch: nil) == true, "adopt: no last → true")
check(shouldAdopt(newEpoch: 200_000, lastEpoch: 100_000) == true, "adopt: later window → true")
check(shouldAdopt(newEpoch: 100_000, lastEpoch: 100_000 + 5 * 3600) == false, "adopt: >2h earlier (old-window flip) → false")
check(shouldAdopt(newEpoch: 100_000 - 600, lastEpoch: 100_000) == true, "adopt: minutes earlier (drift) → true")
check(shouldAdopt(newEpoch: 100_000, lastEpoch: 100_000) == true, "adopt: equal → true")

// MARK: updatedHistory (session trend recording)
let b = 1_000_000.0
var hh = SessionHistory(windowEpoch: nil, points: [])
hh = updatedHistory(hh, sessionEpoch: b + 5 * 3600, pct: 5, now: b)
check(hh.points.count == 1 && hh.windowEpoch == b + 5 * 3600, "history: first point")
hh = updatedHistory(hh, sessionEpoch: b + 5 * 3600, pct: 6, now: b + 10)
check(hh.points.count == 1, "history: within minInterval → not appended")
hh = updatedHistory(hh, sessionEpoch: b + 5 * 3600, pct: 6, now: b + 60)
check(hh.points.count == 2, "history: appended after interval")
hh = updatedHistory(hh, sessionEpoch: b + 5 * 3600 + 120, pct: 7, now: b + 120)
check(hh.points.count == 3 && hh.points.last?.pct == 7, "history: drift keeps points")
hh = updatedHistory(hh, sessionEpoch: b + 10 * 3600, pct: 1, now: b + 180)
check(hh.windowEpoch == b + 10 * 3600 && hh.points.count == 1, "history: new window resets points")
check(updatedHistory(hh, sessionEpoch: b + 10 * 3600, pct: nil, now: b + 300).points.count == 1, "history: nil pct → no point")
var hm = SessionHistory(windowEpoch: b, points: [])
hm = updatedHistory(hm, sessionEpoch: b, pct: 30, now: b)
hm = updatedHistory(hm, sessionEpoch: b, pct: 12, now: b + 60)
check(hm.points.last?.pct == 30, "history: cumulative — dip held at running max")
hm = updatedHistory(hm, sessionEpoch: b, pct: 41, now: b + 120)
check(hm.points.last?.pct == 41, "history: cumulative — rises to new peak")
// reset wipes all old data (no carryover into the new window)
var hp = SessionHistory(windowEpoch: b, points: [HistoryPoint(t: b - 3600, pct: 99)])
hp = updatedHistory(hp, sessionEpoch: b + 5 * 3600, pct: 3, now: b + 5 * 3600)
check(hp.points.count == 1 && hp.points.first?.pct == 3, "history: reset wipes old data")
// prune anything older than the current window even without a detected reset
var hg = SessionHistory(windowEpoch: b, points: [HistoryPoint(t: b - 6 * 3600, pct: 50)])
hg = updatedHistory(hg, sessionEpoch: b, pct: 10, now: b)
check(!hg.points.contains { $0.t < b - 5 * 3600 - 600 }, "history: prunes points older than the window")
var hc = SessionHistory(windowEpoch: b, points: [])
for i in 0 ..< 10 { hc = updatedHistory(hc, sessionEpoch: b, pct: i, now: b + Double(i) * 100, minInterval: 50, maxPoints: 5) }
check(hc.points.count == 5, "history: capped to maxPoints")


// MARK: Codex reading — the collector writes the same key names, plus its own extras
let codexJSON = """
{"session_pct":83,"session_reset_epoch":1788952298,"session_window_mins":300,
 "weekly_all_pct":33,"weekly_all_reset_epoch":1789446032,"weekly_window_mins":10080,
 "plan":"plus","reset_credits":2,"error":null,
 "collected_at":"2026-09-09T08:29:02Z","checked_at":"2026-09-09T08:29:02Z"}
"""
if let x = Usage.parse(Data(codexJSON.utf8)) {
    check(x.sessionPct == 83, "codex parse: sessionPct")
    check(x.sessionEpoch == 1788952298, "codex parse: sessionEpoch")
    check(x.sessionWindowMins == 300, "codex parse: session window mins")
    check(x.weeklyPct == 33, "codex parse: weeklyPct")
    check(x.weeklyWindowMins == 10080, "codex parse: weekly window mins")
    check(x.plan == "plus", "codex parse: plan")
    check(x.resetCredits == 2, "codex parse: reset credits")
    check(x.modelLabel == nil, "codex parse: no Claude-only model row")
} else {
    check(false, "codex parse: valid JSON should decode")
}
// A Claude reading leaves the Codex-only fields nil, and vice versa.
check(Usage.parse(["session_pct": 6]).plan == nil, "parse: plan absent → nil")
check(Usage.parse(["session_pct": 6]).sessionWindowMins == nil, "parse: window mins absent → nil")

// MARK: window lengths
check(sessionWindowSeconds(nil) == 5 * 3600, "window: no reading → 5h fallback")
check(sessionWindowSeconds(Usage.parse(["session_window_mins": 300])) == 5 * 3600, "window: 300 mins → 5h")
check(sessionWindowSeconds(Usage.parse(["session_window_mins": 0])) == 5 * 3600, "window: 0 mins → fallback")
check(sessionMaxSeconds(nil) == 6 * 3600, "windowMax: no reading → 6h fallback")
check(sessionMaxSeconds(Usage.parse(["session_window_mins": 300])) == 6 * 3600, "windowMax: 5h window + 1h slack")
check(sessionMaxSeconds(Usage.parse(["session_window_mins": 60])) == 2 * 3600, "windowMax: 1h window + 1h slack")

// MARK: isCodexAvailable — Codex is optional and hides itself when there is nothing to show
func codex(_ pct: Int? = 83, error: String? = nil, collectedAt: String? = nil,
           checkedAt: String? = nil, epoch: Double? = nil) -> Usage {
    var u = Usage()
    u.sessionPct = pct; u.weeklyPct = 33; u.sessionWindowMins = 300
    u.plan = "plus"; u.resetCredits = 2
    u.error = error; u.collectedAt = collectedAt; u.checkedAt = checkedAt; u.sessionEpoch = epoch
    return u
}
check(isCodexAvailable(nil) == false, "codex: no file → unavailable")
check(isCodexAvailable(codex(error: "not_installed")) == false, "codex: CLI missing → unavailable")
check(isCodexAvailable(codex(error: "logged_out")) == false, "codex: signed out → unavailable")
check(isCodexAvailable(codex(nil, error: nil)) == true, "codex: weekly only still counts")
check(isCodexAvailable(Usage()) == false, "codex: no numbers ever read → unavailable")
check(isCodexAvailable(codex(error: "no_output")) == true,
      "codex: a transient failure keeps the last good values visible")

// MARK: chartProviders
check(chartProviders(.off, codexAvailable: true).isEmpty, "chart: off → nothing")
check(chartProviders(.stacked, codexAvailable: true) == [.claude, .codex], "chart: stacked → both")
check(chartProviders(.overlay, codexAvailable: true) == [.claude, .codex], "chart: overlay → both")
check(chartProviders(.stacked, codexAvailable: false) == [.claude], "chart: stacked, no codex → Claude")
check(chartProviders(.codexOnly, codexAvailable: true) == [.codex], "chart: codex only")
check(chartProviders(.codexOnly, codexAvailable: false) == [.claude],
      "chart: codex only with no codex → falls back to Claude")
check(chartProviders(.claudeOnly, codexAvailable: true) == [.claude], "chart: claude only")

// MARK: menuBarRender — the single-provider format must not change
let live = iso.string(from: now)
func claudeU(session: Int? = 14, weekly: Int? = 25, error: String? = nil,
             epoch: Double? = nil, collectedAt: String? = nil) -> Usage {
    var u = Usage()
    u.sessionPct = session; u.weeklyPct = weekly; u.error = error
    u.sessionEpoch = epoch; u.collectedAt = collectedAt ?? live; u.checkedAt = live
    return u
}
func bar(_ c: Usage?, _ x: Usage? = nil, mode: BarMode = .both, compact: Bool = false,
         animations: Bool = false) -> String {
    barText(menuBarRender(claude: c, codex: x, mode: mode, compact: compact,
                          animations: animations, now: now))
}
let in4h = now.timeIntervalSince1970 + 4 * H

check(bar(nil) == "Claude --", "bar: no data at all")
check(bar(claudeU(epoch: in4h)) == "s14% · w25% · ⏳4:00", "bar: single provider keeps the old format")
check(bar(claudeU(epoch: in4h), compact: true) == "s14% · ⏳4:00", "bar: compact drops weekly")
check(bar(claudeU(epoch: in4h), animations: true) == "s14% · w25% · 4:00",
      "bar: animated single provider drops the ⏳ glyph (the drawn hourglass replaces it)")
check(menuBarRender(claude: claudeU(epoch: in4h), codex: nil, mode: .both, compact: false,
                    animations: true, now: now).icon == .hourglass(4 * 3600, 5),
      "bar: single provider asks for the drawn hourglass")
check(menuBarRender(claude: claudeU(epoch: in4h), codex: nil, mode: .both, compact: false,
                    animations: false, now: now).icon == BarIcon.none,
      "bar: animations off → no image")
check(bar(claudeU(error: "logged_out")) == "⚠ Sign in", "bar: signed out → call to action")
check(bar(claudeU(collectedAt: oldISO)) == "⚠ s14% · w25%", "bar: not updating → dimmed and marked")
check(menuBarRender(claude: claudeU(epoch: now.timeIntervalSince1970 - 10), codex: nil, mode: .both,
                    compact: false, animations: true, now: now).icon == .spinner,
      "bar: mid-reset asks for the spinner")

// MARK: menuBarRender — two providers
let cx = codex(83, collectedAt: live, checkedAt: live, epoch: now.timeIntervalSince1970 + 2 * H)
check(bar(claudeU(epoch: in4h), cx) == "C 14% ⏳4:00 · X 83% ⏳2:00", "bar: both providers")
check(bar(claudeU(epoch: in4h), cx, compact: true) == "C 14% · X 83%", "bar: both, compact")
check(menuBarRender(claude: claudeU(epoch: in4h), codex: cx, mode: .both, compact: false,
                    animations: true, now: now).icon == BarIcon.none,
      "bar: two providers never take the single image slot")
// The two-provider bar draws the same minimal hourglass the single-provider bar puts in the
// image slot, inline so both providers can have one. `text` stays the ⏳ stand-in, which is
// what "Copy status" and VoiceOver read.
func hourglasses(_ c: Usage?, _ x: Usage?, animations: Bool) -> [HourglassSpec] {
    menuBarRender(claude: c, codex: x, mode: .both, compact: false,
                  animations: animations, now: now).segments.compactMap { $0.hourglass }
}
check(hourglasses(claudeU(epoch: in4h), cx, animations: true)
        == [HourglassSpec(remaining: 4 * 3600, windowHours: 5),
            HourglassSpec(remaining: 2 * 3600, windowHours: 5)],
      "bar: both providers each get an inline hourglass, with their own time left")
check(hourglasses(claudeU(epoch: in4h), cx, animations: false).isEmpty,
      "bar: animations off → plain ⏳ text, no drawn icon")
check(hourglasses(claudeU(epoch: now.timeIntervalSince1970 - 10), cx, animations: true).count == 1,
      "bar: a resetting provider shows ↻ instead of an hourglass")
check(hourglasses(claudeU(epoch: in4h), cx, animations: true).map { $0.windowHours } == [5, 5],
      "bar: window hours come from each provider's own window")
// The C / X tags carry the provider's brand colour; nothing else on the bar does, so a
// percentage keeps its own warn/critical colour.
let dualSegs = menuBarRender(claude: claudeU(epoch: in4h), codex: cx, mode: .both,
                             compact: false, animations: true, now: now).segments
check(dualSegs.compactMap { $0.brand } == [.claude, .codex], "bar: exactly the two tags are branded")
check(dualSegs.filter { $0.brand != nil }.map { $0.text } == ["C ", "X "], "bar: the branded runs are the tags")
check(menuBarRender(claude: claudeU(epoch: in4h), codex: nil, mode: .both, compact: false,
                    animations: true, now: now).segments.allSatisfy { $0.brand == nil },
      "bar: a single-provider bar has no tags to brand")
check(bar(claudeU(epoch: in4h), cx, mode: .claudeOnly) == "s14% · w25% · ⏳4:00",
      "bar: claude only ignores an available Codex")
check(bar(claudeU(epoch: in4h), cx, mode: .codexOnly) == "s83% · w33% · ⏳2:00",
      "bar: codex only shows Codex in the single-provider format")
check(bar(claudeU(epoch: in4h), codex(error: "logged_out"), mode: .codexOnly) == "s14% · w25% · ⏳4:00",
      "bar: codex only with no Codex falls back to Claude, never blank")
check(bar(claudeU(error: "logged_out"), cx) == "C ⚠ · X 83% ⏳2:00",
      "bar: a signed-out Claude shrinks to a warning, Codex keeps reporting")
check(bar(claudeU(epoch: in4h, collectedAt: oldISO), cx) == "C ⚠14% · X 83% ⏳2:00",
      "bar: a stalled provider is marked without hiding the other")
check(bar(nil, cx) == "C -- · X 83% ⏳2:00", "bar: missing Claude cache with Codex present")
check(bar(claudeU(epoch: now.timeIntervalSince1970 - 10), cx) == "C 14% ↻ · X 83% ⏳2:00",
      "bar: resetting provider marked inline (no spinner with two providers)")

// MARK: detailLines
let cLines = detailLines(.claude, claudeU(epoch: in4h), now: now)
check(cLines == ["Session: 14% used · 4h 0m left", "Weekly (all models): 25% used · reset time unknown"],
      "detail: Claude rows")
var withModel = claudeU(epoch: in4h)
withModel.modelLabel = "Fable"; withModel.modelPct = 0
check(detailLines(.claude, withModel, now: now).count == 3, "detail: Claude per-model row appears")
let xLines = detailLines(.codex, cx, now: now)
check(xLines[0] == "Session: 83% used · 2h 0m left", "detail: Codex session row")
check(xLines[1].hasPrefix("Weekly: 33% used"), "detail: Codex weekly row has no model qualifier")
check(xLines[2] == "Plan: plus · 2 rate-limit resets available", "detail: Codex plan row")
var oneCredit = cx; oneCredit.resetCredits = 1
check(detailLines(.codex, oneCredit, now: now)[2] == "Plan: plus · 1 rate-limit reset available",
      "detail: reset credit count is singular at 1")
var noCredit = cx; noCredit.resetCredits = 0
check(detailLines(.codex, noCredit, now: now)[2] == "Plan: plus", "detail: no credits → plan only")
check(detailLines(.claude, claudeU(error: "logged_out"), now: now)
        == ["Signed out — usage tracking is paused"], "detail: signed out says so")
check(tooltipText(claude: claudeU(error: "logged_out"), codex: cx, now: now)
        .contains("Claude · Signed out"),
      "tooltip: a signed-out Claude is named once, not twice, alongside Codex")

// MARK: tooltipText
let tip = tooltipText(claude: claudeU(epoch: in4h), codex: cx, now: now)
check(tip.contains("Claude · Session: 14% used"), "tooltip: prefixes providers when there are two")
check(tip.contains("Codex · Session: 83% used"), "tooltip: includes Codex")
let soloTip = tooltipText(claude: claudeU(epoch: in4h), codex: nil, now: now)
check(!soloTip.contains("Claude · "), "tooltip: no prefix with a single provider")
check(soloTip.contains("Updated: "), "tooltip: single provider reports its collection time")
check(tooltipText(claude: claudeU(error: "logged_out"), codex: nil, now: now).contains("Sign in to Claude"),
      "tooltip: signed out points at the fix")
check(tooltipText(claude: nil, codex: cx, now: now).contains("Claude: no data"),
      "tooltip: a missing Claude cache is stated, not hidden")
check(tooltipText(claude: claudeU(epoch: in4h, collectedAt: oldISO), codex: cx, now: now)
        .contains("⚠ Claude: not updating"), "tooltip: names which provider stalled")

print("\n\(total - failed)/\(total) passed" + (failed == 0 ? " ✅" : "  (\(failed) FAILED) ❌"))
exit(failed == 0 ? 0 : 1)
