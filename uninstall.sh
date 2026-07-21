#!/usr/bin/env bash
# Uninstaller for the Claude usage menu bar widget.
# Removes ONLY what this project creates:
#   - launchd agents: com.ososos888.claudeusagebar, com.user.claude-usage
#   - app bundle:      ~/Applications/ClaudeUsageBar.app
#   - data directory:  ~/.claude-usage
# SwiftBar itself is never touched.
#
# Usage:
#   ./uninstall.sh            # ask for confirmation, then remove
#   ./uninstall.sh -y         # remove without confirmation
#   ./uninstall.sh --dry-run  # show exactly what would happen, change nothing
set -euo pipefail

ASSUME_YES=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes)     ASSUME_YES=1 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    -h|--help)    echo "usage: uninstall.sh [-y|--yes] [-n|--dry-run]"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# --- Safety guards -----------------------------------------------------------
# HOME must be a real, non-root directory or we refuse to touch anything.
[[ -n "${HOME:-}" && -d "$HOME" && "$HOME" != "/" ]] || {
  echo "Refusing to run: HOME is invalid ('${HOME:-unset}')." >&2; exit 1; }

APP_LABEL="com.ososos888.claudeusagebar"
COLLECT_LABEL="com.user.claude-usage"
APP_PLIST="$HOME/Library/LaunchAgents/$APP_LABEL.plist"
COLLECT_PLIST="$HOME/Library/LaunchAgents/$COLLECT_LABEL.plist"
APP_DIR="$HOME/Applications/ClaudeUsageBar.app"
DATA_DIR="$HOME/.claude-usage"
APP_BIN="$APP_DIR/Contents/MacOS/ClaudeUsageBar"

# Hard-guard the destructive targets: they must be exactly the expected paths.
[[ "$APP_DIR"  == "$HOME/Applications/ClaudeUsageBar.app" ]] || { echo "path guard failed (app)"  >&2; exit 1; }
[[ "$DATA_DIR" == "$HOME/.claude-usage" ]]                   || { echo "path guard failed (data)" >&2; exit 1; }
# ------------------------------------------------------------------------------

echo "This will remove:"
echo "  - launchd agent: $APP_LABEL"
echo "  - launchd agent: $COLLECT_LABEL"
echo "  - app bundle:    $APP_DIR"
echo "  - data dir:      $DATA_DIR"
echo "  (SwiftBar and any SwiftBar plugin symlink are NOT removed.)"
echo
[[ $DRY_RUN -eq 1 ]] && echo "[dry-run] no changes will be made" && echo

if [[ $ASSUME_YES -ne 1 && $DRY_RUN -ne 1 ]]; then
  read -r -p "Proceed? [y/N] " ans
  case "$ans" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 0 ;; esac
fi

# run CMD... — echo the action; execute it only when not a dry run.
run() { echo "+ $*"; [[ $DRY_RUN -eq 1 ]] || "$@"; }

# 1) Unload + remove launchd agents (only the ones we created, if present)
for pl in "$APP_PLIST" "$COLLECT_PLIST"; do
  if [[ -f "$pl" ]]; then
    echo "+ launchctl unload $pl"
    [[ $DRY_RUN -eq 1 ]] || launchctl unload "$pl" 2>/dev/null || true
    run rm -f "$pl"
  fi
done

# 2) Stop any lingering app process (matched by its exact bundle binary path)
if pgrep -f "$APP_BIN" >/dev/null 2>&1; then
  echo "+ pkill -f $APP_BIN"
  [[ $DRY_RUN -eq 1 ]] || pkill -f "$APP_BIN" 2>/dev/null || true
fi

# 3) Remove the app bundle
[[ -d "$APP_DIR" ]] && run rm -rf "$APP_DIR"

# 4) Remove the data directory
[[ -d "$DATA_DIR" ]] && run rm -rf "$DATA_DIR"

echo
if [[ $DRY_RUN -eq 1 ]]; then
  echo "Dry run complete. Nothing was changed."
else
  echo "Uninstalled. (To reinstall: ./install.sh)"
fi
