// Pure, UI-free logic for ClaudeUsageBar — kept separate so it can be unit-tested with
// plain swiftc (see ../tests/run.sh). No AppKit here.
import Foundation

// Parsed contents of ~/.claude-usage/usage.json (produced by collect.sh).
struct Usage: Equatable {
    var sessionPct: Int?
    var sessionReset: String?
    var sessionEpoch: Double?
    var weeklyPct: Int?
    var weeklyReset: String?
    var weeklyEpoch: Double?
    var modelLabel: String?
    var modelPct: Int?
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
        u.error = str("error"); u.collectedAt = str("collected_at"); u.checkedAt = str("checked_at")
        return u
    }
}

// Severity used to color a menu bar item; mapped to a concrete NSColor in the view layer.
enum UsageLevel { case normal, warn, critical }

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

private let staleISOFormatter = ISO8601DateFormatter()

/// True if the collector's `checked_at` timestamp is older than `staleSeconds`.
func isStale(checkedAt: String?, now: Date = Date(), staleSeconds: Double = 180) -> Bool {
    guard let s = checkedAt, let d = staleISOFormatter.date(from: s) else { return false }
    return now.timeIntervalSince1970 - d.timeIntervalSince1970 > staleSeconds
}
