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
        == Remain(text: "1h0m", resetting: false), "remaining: 1h short")
check(remainingTime(epoch: now.timeIntervalSince1970 + H, maxSeconds: sessionMax, short: false, now: now)
        == Remain(text: "1h 0m left", resetting: false), "remaining: 1h long")
check(remainingTime(epoch: now.timeIntervalSince1970 + 3 * D + 2 * H, maxSeconds: weeklyMax, short: true, now: now)
        == Remain(text: "3d2h", resetting: false), "remaining: 3d2h short")
check(remainingTime(epoch: now.timeIntervalSince1970 + 300, maxSeconds: sessionMax, short: false, now: now)
        == Remain(text: "5m left", resetting: false), "remaining: 5m long")
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

print("\n\(total - failed)/\(total) passed" + (failed == 0 ? " ✅" : "  (\(failed) FAILED) ❌"))
exit(failed == 0 ? 0 : 1)
