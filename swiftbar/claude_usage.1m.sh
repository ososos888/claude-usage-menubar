#!/usr/bin/env bash
# <swiftbar.title>Claude Usage</swiftbar.title>
# <swiftbar.version>1.0.0</swiftbar.version>
# <swiftbar.desc>Show Claude subscription usage (session/weekly) in the menu bar</swiftbar.desc>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
#
# Reads only the cache file (~/.claude-usage/usage.json), so it is light and instant.
# The data is refreshed by the launchd daemon (collect.sh) every minute.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

F="$HOME/.claude-usage/usage.json"

if [[ ! -f "$F" ]]; then
  echo "-- %"
  echo "---"
  echo "No data (daemon not running?) | color=red"
  echo "Run collect.sh now | bash='$HOME/.claude-usage/collect.sh' terminal=false refresh=true"
  exit 0
fi

# Color by threshold: 80%+ red, 60-79% orange
color_for() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || { echo ""; return; }
  if   (( p >= 80 )); then echo "red"
  elif (( p >= 60 )); then echo "orange"
  else echo ""; fi
}
colorpipe() { local c; c="$(color_for "$1")"; [[ -n "$c" ]] && echo "color=$c"; }

# Reset-time string -> remaining time.
#   Input e.g.: "Jul 21 at 6:40pm (Asia/Seoul)" or "Jul 26 at 4am (Asia/Seoul)"
#   style=long  -> "3h 25m left" / "2d 4h left"
#   style=short -> "3h25m" / "2d4h"  (for the menu bar)
remaining() {
  local s="$1" style="${2:-long}"
  [[ -n "$s" && "$s" != "?" ]] || { echo ""; return; }
  local tz="" body="$s"
  if [[ "$s" =~ \(([^\)]+)\)[[:space:]]*$ ]]; then
    tz="${BASH_REMATCH[1]}"
    body="$(printf '%s' "$s" | sed 's/ *([^)]*)[[:space:]]*$//')"
  fi
  # Use %I:%M%p if the time has minutes, otherwise %I%p
  local fmt; [[ "$body" == *:* ]] && fmt="%b %d at %I:%M%p %Y" || fmt="%b %d at %I%p %Y"
  # The system locale (ko_KR) can't read %b (Jul), so force LC_ALL=C
  local dpfx=(env LC_ALL=C); [[ -n "$tz" ]] && dpfx+=(TZ="$tz")
  local yr epoch now
  yr="$("${dpfx[@]}" date +%Y)"
  epoch="$("${dpfx[@]}" date -j -f "$fmt" "$body $yr" +%s 2>/dev/null)" || { echo ""; return; }
  now="$(date +%s)"
  # Roll to next year only for the Dec->Jan boundary (far in the past, >40 days),
  # not for a reset that just elapsed a few minutes ago (which would wrongly show ~364d).
  if (( epoch < now - 3456000 )); then
    epoch="$("${dpfx[@]}" date -j -f "$fmt" "$body $((yr+1))" +%s 2>/dev/null)" || { echo ""; return; }
  fi
  local diff=$(( epoch - now ))
  # Brief reset window: just elapsed / about to elapse / implausibly large (mid-reset parse).
  if (( diff <= 30 || diff > 691200 )); then
    [[ "$style" == short ]] && echo "resetting" || echo "resetting…"
    return
  fi
  local d=$(( diff/86400 )) h=$(( (diff%86400)/3600 )) m=$(( (diff%3600)/60 ))
  if [[ "$style" == short ]]; then
    if   (( d > 0 )); then echo "${d}d${h}h"
    elif (( h > 0 )); then echo "${h}h${m}m"
    else echo "${m}m"; fi
  else
    if   (( d > 0 )); then echo "${d}d ${h}h left"
    elif (( h > 0 )); then echo "${h}h ${m}m left"
    else echo "${m}m left"; fi
  fi
}

S=$(jq -r '.session_pct       // "?"' "$F")
SR=$(jq -r '.session_reset    // "?"' "$F")
W=$(jq -r '.weekly_all_pct    // "?"' "$F")
WR=$(jq -r '.weekly_all_reset // "?"' "$F")
ML=$(jq -r '.weekly_model_label // "-"' "$F")
MP=$(jq -r '.weekly_model_pct   // "-"' "$F")
ERR=$(jq -r '.error // ""' "$F")
CA=$(jq -r '.collected_at // "?"' "$F")

# Compute remaining time until reset
SREM="$(remaining "$SR" long)"    # session remaining, for the dropdown
SREMC="$(remaining "$SR" short)"  # session remaining, compact for the menu bar
WREM="$(remaining "$WR" long)"    # weekly remaining

# Menu bar line (colored by session %). s = session (5-hour rolling), w = weekly
BAR="s${S}% · w${W}%"
if [[ "$SREMC" == "resetting" ]]; then
  BAR="$BAR · ↻ resetting"
elif [[ -n "$SREMC" ]]; then
  BAR="$BAR · ⏳${SREMC}"
fi
BARCOLOR="$(color_for "$S")"
if [[ -n "$BARCOLOR" ]]; then
  echo "$BAR | color=$BARCOLOR"
else
  echo "$BAR"
fi

echo "---"
[[ -n "$ERR" ]] && echo "⚠️ Last update failed: $ERR (showing last good values) | color=red"
echo "Session: ${S}% used · ${SREM:-resets $SR} $([[ -n "$SREM" ]] && echo "(resets $SR)") | $(colorpipe "$S")"
echo "Weekly (all models): ${W}% used · ${WREM:-resets $WR} $([[ -n "$WREM" ]] && echo "(resets $WR)") | $(colorpipe "$W")"
echo "Weekly (${ML}): ${MP}%"
echo "---"
echo "Updated: ${CA}"
echo "Refresh now | bash='$HOME/.claude-usage/collect.sh' terminal=false refresh=true"
echo "Open Claude usage page | href=https://claude.ai/settings/usage"
