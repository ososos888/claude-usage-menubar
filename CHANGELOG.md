# Changelog

All notable changes to this project are documented here. This project adheres to
[Semantic Versioning](https://semver.org/) and the format of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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

[1.2.2]: https://github.com/ososos888/claude-usage-menubar/releases/tag/v1.2.2
[1.2.1]: https://github.com/ososos888/claude-usage-menubar/releases/tag/v1.2.1
[1.2.0]: https://github.com/ososos888/claude-usage-menubar/releases/tag/v1.2.0
[1.1.0]: https://github.com/ososos888/claude-usage-menubar/releases/tag/v1.1.0
[1.0.0]: https://github.com/ososos888/claude-usage-menubar/releases/tag/v1.0.0
