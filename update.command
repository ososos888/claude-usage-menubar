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
./standalone/build.sh

echo
echo "Updated to $(git describe --tags --abbrev=0 2>/dev/null || echo 'latest'). You can close this window."
