#!/usr/bin/env bash
# Installer for the Claude usage menu bar app (standalone native app).
#   1) Place collect.sh (and collect-codex.sh) into ~/.claude-usage
#   2) Register the launchd daemons (collect every 1 minute)
#   3) Build/install the native menu bar app (ClaudeUsageBar) and register auto-start
# The Codex half is optional: its collector and agent are always installed, but they exit
# immediately when the Codex CLI is missing or signed out, and the app then stays Claude-only.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.claude-usage"
PLIST="$HOME/Library/LaunchAgents/com.user.claude-usage.plist"
CODEX_PLIST="$HOME/Library/LaunchAgents/com.user.codex-usage.plist"

echo "==> Checking prerequisites"
command -v jq      >/dev/null || { echo "jq is required: brew install jq"; exit 1; }
command -v claude  >/dev/null || { echo "Claude Code (claude) is required: https://claude.com/claude-code"; exit 1; }
command -v swiftc  >/dev/null || { echo "Swift compiler is required: xcode-select --install"; exit 1; }

echo "==> Installing collectors: $DEST"
mkdir -p "$DEST"
install -m 755 "$HERE/collect.sh"       "$DEST/collect.sh"
install -m 755 "$HERE/collect-codex.sh" "$DEST/collect-codex.sh"

if command -v codex >/dev/null; then
  echo "    Codex CLI found — Codex usage will be tracked alongside Claude"
else
  echo "    Codex CLI not found — the widget stays Claude-only (install codex later and it appears)"
fi

echo "==> Collecting once"
"$DEST/collect.sh"       || true
"$DEST/collect-codex.sh" || true

echo "==> Registering collector daemons (every 1 minute)"
cp "$HERE/com.user.claude-usage.plist" "$PLIST"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load  "$PLIST"
cp "$HERE/com.user.codex-usage.plist" "$CODEX_PLIST"
launchctl unload "$CODEX_PLIST" 2>/dev/null || true
launchctl load  "$CODEX_PLIST"

echo "==> Building/installing the menu bar app"
"$HERE/standalone/build.sh"

cat <<'EOF'

Done. When the menu bar shows 's..% · w..% · ⏳<time left>', you're set.
(No SwiftBar or other app needed. It auto-starts at login.)

Prefer SwiftBar instead? See swiftbar/claude_usage.1m.sh.
EOF
