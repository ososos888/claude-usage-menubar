# Changelog

All notable changes to this project are documented here. This project adheres to
[Semantic Versioning](https://semver.org/) and the format of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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

[1.0.0]: https://github.com/ososos888/claude-usage-menubar/releases/tag/v1.0.0
