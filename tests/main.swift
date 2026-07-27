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

print("\n\(total - failed)/\(total) passed" + (failed == 0 ? " ✅" : "  (\(failed) FAILED) ❌"))
exit(failed == 0 ? 0 : 1)
