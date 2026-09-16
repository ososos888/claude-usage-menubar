# claude-usage-menubar

[![tests](https://github.com/ososos888/claude-usage-menubar/actions/workflows/tests.yml/badge.svg)](https://github.com/ososos888/claude-usage-menubar/actions/workflows/tests.yml)

A tiny native macOS menu bar app that always shows your Claude subscription (Pro/Max/Team) usage — and your OpenAI Codex usage next to it when you're signed in to both. No more opening Settings → Usage every time — see your session/weekly usage and the time left until reset at a glance.

<p align="center">
  <img src="docs/preview.svg" width="560" alt="Menu bar showing 's14% · w25% · ⏳3:58' with an open dropdown listing session, weekly, and actions">
</p>

```
s14% · w25% · ⏳3:58
```

`s` = session (5-hour rolling), `w` = weekly, `⏳` = time left until the session resets, as `h:mm`. Click it for the details dropdown:

```
Session: 14% used · 3h 58m left
Weekly (all models): 25% used · 4d 14h left
Weekly (Fable): 0%
─────────────
Updated: 2026-07-27T01:19:00Z
Refresh now
Copy status
Open usage page
─────────────
✓ Animations
  Compact (session only)
Trend chart             ▸
Usage alerts            ▸
✓ Start at login
─────────────
Check for Updates…
About (v1.8.1)
Quit
```

Signed in to the [Codex CLI](https://developers.openai.com/codex/cli/) as well, both are shown — session usage and time left for each, tagged `C` for Claude and `X` for Codex:

```
C 14% ⧗3:58 · X 83% ⧗2:47
```

```
Session trend (this window)
[Claude chart]
[Codex chart]
Enlarge graph
─────────────
CLAUDE
Session: 14% used · 3h 58m left
Weekly (all models): 25% used · 4d 14h left
Weekly (Fable): 0%
CODEX
Session: 83% used · 2h 47m left
Weekly: 33% used · 5d 17h left
Plan: plus · 2 rate-limit resets available
─────────────
Updated: Claude 2026-09-09T08:39:04Z · Codex 2026-09-09T08:39:55Z
Refresh now
Copy status
Open usage page        ▸
─────────────
✓ Animations
  Compact (session only)
Menu bar                ▸
Trend chart             ▸
Usage alerts            ▸
✓ Start at login
─────────────
Check for Updates…
About (v1.8.1)
Quit
```

Weekly percentages move to the dropdown in the two-provider bar — four percentages plus two clocks is more width than a menu bar should take. Nothing changes if you don't use Codex: no CLI, or signed out, and the widget stays exactly as it was.

No third-party app like SwiftBar required. Because it only reads a local file, it triggers virtually no macOS permission prompts.

Extras (all lightweight, from the menu):

- **Session trend** — a mini line chart of this session's cumulative usage at the top of the dropdown; resets when the session resets. Both axes are fixed — the full 5-hour window across, the full 0–100% budget up (gridlines every 25%) — so the shape is comparable between sessions. A dashed **even-pace** diagonal (0% at 0h → 100% at 5h) shows whether you're on track: below it the budget lasts the window, above it it runs out early.
- **Enlarge** — click the trend chart (or "Enlarge graph") to open a larger floating window.
- **Codex alongside Claude** — when the Codex CLI is installed and signed in, its 5-hour and weekly rate-limit windows are collected and shown next to Claude's, with their own trend chart, alerts, and usage-page link. The x-axis is *hours since each provider's own reset*, so two windows that started at different times still line up by session progress and can be compared directly.
- **Display options** — **Menu bar** picks which providers reach the bar (Claude + Codex / Claude only / Codex only); **Trend chart** picks how the charts are drawn (two stacked charts / one overlaid chart with a legend / one provider only / off). Both are persisted, and the two-provider entries appear only once Codex is readable.
- **Provider colors** — Claude is orange, Codex is blue, wherever the two appear together: the `C` / `X` tags on the menu bar and the trend lines (and their legend) in the dropdown. Each hue has a darker shade for light appearance and a lighter one for dark.
- **Per-item colors** — session %, weekly %, and time-left are each colored by their own state (session/weekly: 60%+ orange, 80%+ red; time: orange within 60 min of reset, red within 15 min).
- **Tooltip** — hover the icon for the full breakdown without clicking.
- **Copy status** — copies exactly what the menu bar reads, so a pasted status always matches the screen (`s14% · w25% · 3:58`, or `C 14% 3:58 · X 83% 2:47` with both providers).
- **Usage alerts** — opt-in macOS notification when session or weekly crosses a chosen threshold (70 / 80 / 90%), plus a note when a session resets.
- **Compact mode** — show only the session item to save menu bar width.
- **Stale indicator** — if the collector stops updating (or its last run failed), the text dims and shows ⚠ instead of passing old numbers off as current.
- **Signed-out handling** — if Claude Code is signed out, usage can't be read at all, so the menu bar says **⚠ Sign in**, the dropdown offers "Sign in to Claude…" (opens a Terminal running `claude auth login`), and you get one notification — not a stream of them.
- **Start at login** — toggle auto-start (backed by the launchd agent).
- **Check for updates** — compares against the latest GitHub release; if newer, one click opens a Terminal that pulls the latest source and rebuilds (the app restarts itself).
- **About** — opens the project page and shows the version.
- **VoiceOver** — the icon exposes the full status as an accessibility label.

## How it works

```
launchd (1 min)   collect.sh               usage.json           ClaudeUsageBar.app (30s refresh)
   ───────────▶  parse /usage & normalize  ──▶ ~/.claude-usage/ ──▶ menu bar + dropdown
   ───────────▶  collect-codex.sh          ──▶ codex-usage.json ──▶
                 app-server rate limits
```

- **Claude data source**: Claude Code's `claude -p "/usage" --output-format json --no-session-persistence`. This slash command is handled locally, so it **costs zero tokens/usage** (`num_turns: 0`, `output_tokens: 0`), and the flag keeps a once-a-minute collection from leaving ~1,440 throwaway session transcripts a day under `~/.claude/projects/`.
- **Codex data source**: the Codex CLI's app-server, asked over JSON-RPC on stdio for `account/rateLimits/read` — the same rate-limit snapshot the Codex TUI's `/status` renders. It returns `primary` (the rolling 5-hour window) and `secondary` (the weekly one) as `usedPercent` + `resetsAt` + `windowDurationMins`. No thread and no turn is ever started, so it **costs zero tokens** and, unlike `codex exec`, leaves nothing behind under `~/.codex/sessions`. One collection takes ~1.5 s.
- **Why a daemon + cache**: calling `claude` on every render would be slow. A background daemon collects once a minute into a JSON cache, and the app just reads that file for an instant, stable display.
- **Time left** is accurate to the minute: both collectors store reset times as absolute epochs (Codex's API returns one directly), and the app recomputes remaining time on every render. The menu bar shows it as a clock — `3:58` — because two providers side by side have to earn every character.
- **Signed out is detected, not guessed**: signed out, `claude -p "/usage"` still exits 0 and just prints no numbers, so the collector checks the credential store (and `claude auth status --json`) to tell "signed out" apart from "format changed". Freshness is tracked with `collected_at` — the last *successful* collection — so a failing collector can never make old numbers look live.
- **Codex is optional, and silent when absent**: no CLI (`not_installed`) or nobody signed in (`logged_out`) simply hides the Codex half — no warning, no notification, no second sign-in nag. Its collector checks for `~/.codex/auth.json` before spawning anything, so a Mac without Codex doesn't start a process every minute. A *transient* failure behaves like Claude's: the last good values stay, marked stale.
- The web app, desktop app, and Claude Code **share the same usage pool**, so reading one source (Claude Code) reflects total usage.

## Requirements

- macOS 12+
- [Claude Code](https://claude.com/claude-code) — signed in with a subscription account (a subscription login session, not an API key)
- [`jq`](https://jqlang.github.io/jq/) — `brew install jq`
- *(optional)* [Codex CLI](https://developers.openai.com/codex/cli/) 0.150+ signed in with `codex login` — only needed for the Codex half; without it the widget is Claude-only
- Swift compiler — `xcode-select --install` (Command Line Tools)

## Install

```bash
git clone https://github.com/ososos888/claude-usage-menubar.git
cd claude-usage-menubar
./install.sh
```

`install.sh` registers the collector daemons and builds/installs the menu bar app with auto-start. When it's done, the menu bar shows `s..% · w..% · ⏳..`.

## Layout

| Path | Role |
|---|---|
| `collect.sh` | Parses `/usage` output into `~/.claude-usage/usage.json` (including reset epochs). Keeps the last good values on failure and records *why* it failed (`logged_out`, `auth_expired`, `no_numbers`, …) |
| `collect-codex.sh` | Same contract for Codex: asks the Codex app-server for `account/rateLimits/read` and writes `~/.claude-usage/codex-usage.json`. Uses the same key names, so one parser reads both providers |
| `com.user.claude-usage.plist` | launchd agent. Runs `collect.sh` every minute; starts at login |
| `com.user.codex-usage.plist` | launchd agent for `collect-codex.sh`. Installed always; exits immediately when Codex isn't there |
| `standalone/*.swift` | App source, split by concern: `UsageLogic.swift` (pure logic), `HourglassIcon.swift` (icon drawing), `SparkChartView.swift` (trend chart), `AppDelegate.swift` (controller), `main.swift` (entry) |
| `standalone/build.sh` | Compiles `standalone/*.swift` → `~/Applications/ClaudeUsageBar.app` → registers launchd auto-start |
| `tests/run.sh` | Unit tests for the pure logic (plain `swiftc`, no XCTest/SPM) |
| `uninstall.sh` | Removes the agents, app, and data dir (guarded; supports `--dry-run` / `-y`) |
| `update.command` | Double-clickable updater (`git pull`, refresh the installed collector, rebuild the app); also used by in-app "Check for Updates" |
| `swiftbar/claude_usage.1m.sh` | (Optional) plugin alternative if you prefer SwiftBar |

## Customizing

- **Collection interval**: `StartInterval` (seconds) in `com.user.claude-usage.plist` and `com.user.codex-usage.plist`. Default 60.
- **Display refresh**: the `Timer` interval in `AppDelegate.swift` (default 30s).
- **Color thresholds**: `level(forPct:)` and `timeLevel(_:)` in `UsageLogic.swift`. Each item is colored independently — session % and weekly % at 60%+ orange / 80%+ red; time-left at ≤60 min orange / ≤15 min red.
- **Provider colors**: `claudeInk` / `codexInk` in `AppDelegate.swift`, each a light/dark pair. They drive both the menu bar tags and the chart lines, so changing one changes both.
- **Provider tags**: `Provider.tag` in `UsageLogic.swift` (`C` / `X`), used only in the two-provider bar.
- **Animations**: toggle from the menu ("Animations", persisted across launches). When on, the icon is a drawn hourglass whose sand tracks session time left (stepped ~hourly), spins while a session is resetting, flips one full turn when you hit "Refresh now", and the text pulses when a percentage changes. When off, a plain ⏳/↻ emoji with no motion. A status item has exactly one image slot, so with both providers on the bar the hourglass is drawn **inline in the title** instead — smaller, since it shares the line with text — which is how each provider gets its own. The reset spinner and the refresh flip need the image slot, so they run only in single-provider mode; a resetting provider is marked `↻` instead.

After editing, run `./standalone/build.sh` to rebuild and apply immediately.

## Tests

The pure logic (JSON parsing for both providers, menu bar and tooltip rendering,
remaining-time formatting, color thresholds, version compare, staleness) lives in
`standalone/UsageLogic.swift` and is covered by unit tests:

```bash
./tests/run.sh
```

It compiles the logic with plain `swiftc` (no XCTest/SPM) and exits non-zero on failure.

## Uninstall

```bash
./uninstall.sh              # asks for confirmation, then removes everything
./uninstall.sh --dry-run    # show exactly what would be removed, change nothing
./uninstall.sh -y           # skip the confirmation prompt
```

It removes only what this project creates — the three launchd agents, `~/Applications/ClaudeUsageBar.app`, and `~/.claude-usage` — and never touches SwiftBar. Prefer to do it by hand? The equivalent commands:

```bash
launchctl unload ~/Library/LaunchAgents/com.ososos888.claudeusagebar.plist
launchctl unload ~/Library/LaunchAgents/com.user.claude-usage.plist
launchctl unload ~/Library/LaunchAgents/com.user.codex-usage.plist
rm ~/Library/LaunchAgents/com.ososos888.claudeusagebar.plist
rm ~/Library/LaunchAgents/com.user.claude-usage.plist
rm ~/Library/LaunchAgents/com.user.codex-usage.plist
rm -rf ~/Applications/ClaudeUsageBar.app ~/.claude-usage
```

## Notes

- Parsing `/usage` output is an **unofficial path**. If Anthropic changes the output format, update the parser in `collect.sh` (the app then shows `Claude --`).
- The Codex app-server protocol is marked **experimental** by the CLI, so `account/rateLimits/read` may be renamed or reshaped by a Codex release. When that happens the collector writes `no_numbers` or `rpc_error`, the Codex half disappears, and the Claude half is unaffected — the fix is in `collect-codex.sh`.
- To read subscription usage, `claude` must be authenticated with a **subscription login session**. If it's authenticated via `ANTHROPIC_API_KEY`, it bills against the API and behaves differently.
- On the Team plan, limits are **per member**; this widget reflects the currently signed-in account.

## Versioning

This project follows [Semantic Versioning](https://semver.org/). See [CHANGELOG.md](CHANGELOG.md). Current version: **1.8.1**.

## License

MIT
