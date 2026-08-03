# Changelog

All notable changes to this project are documented here. This project adheres to
[Semantic Versioning](https://semver.org/) and the format of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.6.0] - 2026-08-03

### Fixed
- **Signed out of Claude Code, the hourglass used to spin on "resetting" forever.** Signed
  out, `claude -p "/usage"` still exits 0 and simply prints no usage numbers, so the
  collector kept the previous values and only refreshed `checked_at`. Two things followed:
  the staleness check (which reads `checked_at`) never fired, so the menu bar showed old
  figures as if they were live; and the preserved reset time eventually elapsed, which reads
  as a reset — spinning the icon indefinitely and re-running the collector every 5 seconds.
  Freshness is now judged on `collected_at` (the last *successful* collection), and the reset
  animation, the fast polling, and trend recording are all gated on collection succeeding.

### Added
- Signed-out state is now detected and surfaced instead of being silently wrong:
  - the menu bar becomes a red **⚠ Sign in** instead of showing unrefreshable numbers;
  - the dropdown leads with **Sign in to Claude…**, which opens a Terminal window running
    `claude auth login` and re-collects a few times afterwards, so the menu bar recovers
    without waiting for the next launchd tick;
  - a notification fires **once per signed-out episode** (re-armed only after usage is
    readable again), since this is the one failure that can't clear up on its own.
- The collector distinguishes `logged_out` (no credentials, or `claude auth status` says so)
  from `auth_expired` (credentials present but `/usage` produced nothing) and `no_numbers`
  (output present but unparsable — our bug to fix). It probes the credential store before
  spawning the CLI, so a signed-out Mac stops starting a `claude` process every minute.

### Changed
- Session trend chart y-axis is now the fixed **0–100% budget with solid gridlines every
  25%**, instead of auto-scaling to the session's peak. Auto-scaling made 4% of the budget
  fill the whole chart; a fixed axis means the line's height means the same thing every
  session, at the cost of looking reassuringly flat on a light day.

## [1.5.0] - 2026-07-28

### Added
- Enlarge the session trend chart: click the mini chart in the dropdown (or the new
  "Enlarge graph" menu item) to open a larger floating window with the same chart. The
  chart's fonts and strokes scale with the view size, so it's crisp at either size.

## [1.4.4] - 2026-07-28

### Changed
- Session trend chart x-axis is now the fixed 5-hour session window, labeled from the reset
  forward (`0h · 1h · 2h · 3h · 4h · 5h`) instead of relative-to-now (`-3h … now`). The
  measured data fills its portion; the rest of the window stays blank.

## [1.4.3] - 2026-07-28

### Changed
- Session trend chart: the x-axis now spans the full session window (reset → now), and the
  line covers only actually-measured samples — the unmeasured early part (before recording
  started) is left blank instead of interpolating a fake 0% start. Better empty than wrong.

### Fixed
- Robust per-session cleanup so stale data can't pile up: history is fully wiped on each
  reset, points older than the current window are pruned on every update (covers a missed
  reset), and corrupt/out-of-range points are dropped on load.

## [1.4.2] - 2026-07-28

### Changed
- Session trend chart is now **cumulative since reset**: it only rises (or stays flat) and
  resets to 0 at each session reset. It previously plotted the raw rolling-window %, which
  can dip as old usage ages out; the chart now holds the running peak within a window
  (matching "usage since reset can't go down"). Existing history is migrated on load.

## [1.4.1] - 2026-07-28

### Changed
- Session trend chart now has an x-axis: the line is plotted against real time, with dotted
  vertical gridlines and labels at round intervals (e.g. -3h / -2h / -1h / now).

## [1.4.0] - 2026-07-28

### Added
- Session usage trend: a mini line/area chart of the current session's usage over time at
  the top of the dropdown, resetting with each session window. Sampled ~once per minute
  and stored in `~/.claude-usage/session-history.json`. (`SparkChartView.swift` +
  `updatedHistory()` in `UsageLogic.swift`, unit-tested.)

### Fixed
- Widget could stop updating for several minutes after a session reset. When `/usage`
  briefly reports "0% used" with no reset time (right after a reset), `collect.sh` could
  leave `usage.json` empty, and a once-empty/corrupt file stayed stuck (the app couldn't
  parse it). `collect.sh` now never writes or keeps an empty/invalid file, and the app
  fast-polls while the reset time is temporarily missing.

## [1.3.4] - 2026-07-28

### Fixed
- Repeated "session reset" notifications (arriving ~every minute, even at 0% usage) and
  jumpy values shown right after a reset. Around a reset, `/usage` flips for a while between
  the just-expired window and the new one — each flip moved the reported reset time ~5h,
  which re-triggered the alert and bounced the displayed numbers. The app now ignores a
  reading that jumps >2h back to an already-expired window (keeps the later/new one), and
  the reset alert fires at most once per window (dedup on the reset epoch).

## [1.3.3] - 2026-07-27

### Changed
- Faster display update at a session reset. The spinning icon never re-read the cache, so
  the bar could keep spinning for up to a refresh cycle after the new window was already
  written. The spinner now re-reads the cache ~every 1.5s (leaving "resetting" promptly),
  and the reset poll interval dropped 8s → 5s.

## [1.3.2] - 2026-07-27

### Added
- GitHub Actions CI (`.github/workflows/tests.yml`): runs the unit tests on a
  GitHub-hosted macOS runner on every push/PR. Free for this public repo.

### Fixed
- Corrected stale file/function references in the README "Customizing" section after
  the source split (`AppDelegate.swift`, `level`/`timeLevel` in `UsageLogic.swift`).

## [1.3.1] - 2026-07-27

### Changed
- Split the single 640-line source into focused files: `UsageLogic.swift` (pure,
  UI-free logic), `HourglassIcon.swift` (icon drawing), `AppDelegate.swift` (controller),
  `main.swift` (entry). `build.sh` now compiles `standalone/*.swift`. No behavior change.

### Added
- Unit tests for the pure logic in `tests/` (parsing, remaining-time formatting, color
  thresholds, version compare, staleness), run with `./tests/run.sh` via plain `swiftc`.

## [1.3.0] - 2026-07-27

### Added
- "Check for Updates…" menu item: compares the app version against the latest GitHub
  release and, if newer, opens a Terminal that pulls the latest source and rebuilds (the
  app restarts itself). Uses `update.command`; the source repo path is embedded at build
  time so the app knows where to update from.

## [1.2.5] - 2026-07-27

### Changed
- Faster update right after a session reset. Instead of waiting for the next launchd
  collection (up to ~a minute), the app now polls every 8s during the last ~90s before
  and throughout a reset, so the new window appears within seconds. It self-stops once
  the new window loads (with a ~3 min safety cap).

## [1.2.4] - 2026-07-27

### Fixed
- Menu bar could stay stale for many minutes after the Mac woke from sleep. As a
  background (accessory) app it was subject to App Nap, which suspended the refresh
  timer — the collector kept the JSON fresh, but the app stopped re-reading it. The app
  now opts out of App Nap (idle system sleep still allowed) and refreshes immediately on
  `NSWorkspace.didWakeNotification` (with a short retry while the network comes back).

## [1.2.3] - 2026-07-22

### Fixed
- Reset notification still false-fired repeatedly: the reported session reset time drifts
  by a few minutes as the rolling window ages, and the previous >60s threshold caught that
  drift. A real reset only happens at expiry and jumps the reset time ~a full window (~5h)
  forward at once, so it now requires a >3h jump.

## [1.2.2] - 2026-07-22

### Fixed
- The "resetting" spinner no longer wobbles. It cycled block glyphs (◐◓◑◒) whose
  advance widths differed frame to frame, jittering the title. It now smoothly rotates
  the hourglass icon in a fixed-size square canvas, so the width stays constant.

## [1.2.1] - 2026-07-22

### Fixed
- Reset notification no longer false-fires. It keyed off any drop in session %, but a
  rolling 5-hour window's % dips on its own as old usage ages out. It now triggers only
  when the session reset time advances to a new window.

## [1.2.0] - 2026-07-22

### Added
- Selectable usage-alert threshold (Off / 70% / 80% / 90%) via a submenu.
- Reset notification: when a session resets, an alert notes capacity is back (requires alerts on).
- Compact mode (menu toggle): show only the session item to save menu bar width.
- Stale-data indicator: if the collector daemon stops updating, the menu bar dims and shows ⚠.
- About item (opens the project page; shows the app version).
- VoiceOver accessibility label carrying the full status.

### Changed
- Menu bar coloring is now per-item: session %, weekly %, and time-left are each
  colored by their own state, instead of a single color for the whole title.
  (session/weekly: 60%+ orange, 80%+ red; time: ≤60 min orange, ≤15 min red.)

### Fixed
- Colored menu bar text reverts to the default color while the menu is open, so it
  reads correctly on the blue highlight.

## [1.1.0] - 2026-07-22

### Added
- README preview figure (`docs/preview.svg`) showing the menu bar item and dropdown.
- `uninstall.sh`: guarded uninstaller (path guards, confirmation prompt, `--dry-run`
  and `-y` flags) that removes only what this project installs; never touches SwiftBar.
- Optional animations (menu toggle, persisted via UserDefaults): a drawn hourglass icon
  whose sand tracks session time left (stepped ~hourly), a spinner while a session is
  resetting, a full-turn hourglass flip when "Refresh now" is pressed, and a pulse when a
  percentage changes. Off falls back to a plain emoji.
- Tooltip with the full session/weekly breakdown on hover.
- "Copy status" menu item (copies the compact status to the clipboard).
- Opt-in usage alerts: a macOS notification when session or weekly crosses 80%
  (re-arms after dropping back below). Menu toggle, persisted.
- "Start at login" menu toggle, backed by enabling/disabling the launchd agent
  (does not kill the running app).
- Reset-imminent emphasis: the menu bar text turns red when the session resets
  within 15 minutes.
- Build now ad-hoc code-signs the app bundle (free) so notifications work reliably
  and Gatekeeper is satisfied.

### Fixed
- Session reset window no longer shows a nonsensical "364d23h" (and no red "Claude --"
  flash): during the brief reset window the widget now shows "↻ resetting". Root cause
  was over-eager year rollover in `collect.sh` — it now only rolls to next year for the
  Dec->Jan boundary (>40 days in the past), not for a reset that just elapsed. The app
  also reuses the last good values on a transient read failure.

## [1.0.0] - 2026-07-21

### Added
- Native macOS menu bar app (`ClaudeUsageBar`) built on `NSStatusItem`; no SwiftBar or
  other third-party app required.
- `collect.sh` daemon that parses `claude -p "/usage" --output-format json` into a
  normalized `~/.claude-usage/usage.json` cache. Collecting costs zero tokens/usage.
- Reset times stored as absolute epochs so the app computes time-left live, accurate to
  the minute.
- launchd agents: collector runs every minute; the app auto-starts at login.
- `install.sh` one-shot installer and `standalone/build.sh` app builder.
- Color thresholds in the menu bar (80%+ red, 60%+ orange).
- Optional SwiftBar plugin (`swiftbar/claude_usage.1m.sh`) for users who prefer SwiftBar.

[1.5.0]: https://github.com/ososos888/claude-usage-menubar/releases/tag/v1.5.0
[1.4.4]: https://github.com/ososos888/claude-usage-menubar/releases/tag/v1.4.4
[1.4.3]: https://github.com/ososos888/claude-usage-menubar/releases/tag/v1.4.3
[1.4.2]: https://github.com/ososos888/claude-usage-menubar/releases/tag/v1.4.2
[1.4.1]: https://github.com/ososos888/claude-usage-menubar/releases/tag/v1.4.1
[1.4.0]: https://github.com/ososos888/claude-usage-menubar/releases/tag/v1.4.0
[1.3.4]: https://github.com/ososos888/claude-usage-menubar/releases/tag/v1.3.4
[1.3.3]: https://github.com/ososos888/claude-usage-menubar/releases/tag/v1.3.3
[1.3.2]: https://github.com/ososos888/claude-usage-menubar/releases/tag/v1.3.2
[1.3.1]: https://github.com/ososos888/claude-usage-menubar/releases/tag/v1.3.1
[1.3.0]: https://github.com/ososos888/claude-usage-menubar/releases/tag/v1.3.0
[1.2.5]: https://github.com/ososos888/claude-usage-menubar/releases/tag/v1.2.5
[1.2.4]: https://github.com/ososos888/claude-usage-menubar/releases/tag/v1.2.4
[1.2.3]: https://github.com/ososos888/claude-usage-menubar/releases/tag/v1.2.3
[1.2.2]: https://github.com/ososos888/claude-usage-menubar/releases/tag/v1.2.2
[1.2.1]: https://github.com/ososos888/claude-usage-menubar/releases/tag/v1.2.1
[1.2.0]: https://github.com/ososos888/claude-usage-menubar/releases/tag/v1.2.0
[1.1.0]: https://github.com/ososos888/claude-usage-menubar/releases/tag/v1.1.0
[1.0.0]: https://github.com/ososos888/claude-usage-menubar/releases/tag/v1.0.0
