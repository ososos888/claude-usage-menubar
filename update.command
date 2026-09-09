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
echo "== Refreshing the collectors =="
mkdir -p "$HOME/.claude-usage"
install -m 755 collect.sh       "$HOME/.claude-usage/collect.sh"
install -m 755 collect-codex.sh "$HOME/.claude-usage/collect-codex.sh"

# Reload an agent whose plist changed, and register the Codex agent on an installation that
# predates it — otherwise updating would leave the Codex half without a daemon to feed it.
for label in com.user.claude-usage com.user.codex-usage; do
  PLIST="$HOME/Library/LaunchAgents/$label.plist"
  if [ ! -f "$PLIST" ] && [ "$label" = "com.user.codex-usage" ]; then
    cp "$label.plist" "$PLIST"
    launchctl load "$PLIST"
    echo "registered the Codex collector daemon"
  elif [ -f "$PLIST" ] && ! cmp -s "$label.plist" "$PLIST"; then
    cp "$label.plist" "$PLIST"
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"
    echo "$label reloaded (its schedule changed)"
  fi
done

./standalone/build.sh

echo
echo "Updated to $(git describe --tags --abbrev=0 2>/dev/null || echo 'latest'). You can close this window."
