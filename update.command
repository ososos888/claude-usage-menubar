#!/usr/bin/env bash
# Double-clickable / "Check for Updates" target: pull the latest source and rebuild.
# Runs in its own Terminal window (independent of the app), so the app restarting
# mid-build is fine.
set -e
cd "$(dirname "$0")"

echo "== Updating claude-usage-menubar =="
echo "repo: $(pwd)"
echo

git pull --ff-only

# Refresh the collector as well. Until v1.6.1 this step was missing, so updating only ever
# rebuilt the app: any collect.sh fix stayed in the repo and ~/.claude-usage kept running
# whatever version install.sh first copied there.
echo
echo "== Refreshing the collector =="
mkdir -p "$HOME/.claude-usage"
install -m 755 collect.sh "$HOME/.claude-usage/collect.sh"
PLIST="$HOME/Library/LaunchAgents/com.user.claude-usage.plist"
if [ -f "$PLIST" ] && ! cmp -s com.user.claude-usage.plist "$PLIST"; then
  cp com.user.claude-usage.plist "$PLIST"
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST"
  echo "collector daemon reloaded (its schedule changed)"
fi

./standalone/build.sh

echo
echo "Updated to $(git describe --tags --abbrev=0 2>/dev/null || echo 'latest'). You can close this window."
