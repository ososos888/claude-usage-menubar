#!/usr/bin/env bash
# Installer for the Claude usage menu bar app (standalone native app).
#   1) Place collect.sh into ~/.claude-usage
#   2) Register the launchd daemon (collect every 1 minute)
#   3) Build/install the native menu bar app (ClaudeUsageBar) and register auto-start
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.claude-usage"
PLIST="$HOME/Library/LaunchAgents/com.user.claude-usage.plist"

echo "==> Checking prerequisites"
command -v jq      >/dev/null || { echo "jq is required: brew install jq"; exit 1; }
command -v claude  >/dev/null || { echo "Claude Code (claude) is required: https://claude.com/claude-code"; exit 1; }
command -v swiftc  >/dev/null || { echo "Swift compiler is required: xcode-select --install"; exit 1; }

echo "==> Installing collector: $DEST"
mkdir -p "$DEST"
cp "$HERE/collect.sh" "$DEST/collect.sh"
chmod +x "$DEST/collect.sh"

echo "==> Collecting once"
"$DEST/collect.sh" || true

echo "==> Registering collector daemon (every 1 minute)"
cp "$HERE/com.user.claude-usage.plist" "$PLIST"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load  "$PLIST"

echo "==> Building/installing the menu bar app"
"$HERE/standalone/build.sh"

cat <<'EOF'

Done. When the menu bar shows 's..% · w..% · ⏳<time left>', you're set.
(No SwiftBar or other app needed. It auto-starts at login.)

Prefer SwiftBar instead? See swiftbar/claude_usage.1m.sh.
EOF
