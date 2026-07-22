#!/usr/bin/env bash
# Claude usage collector daemon.
# Data path A: parse the .result text of `claude -p "/usage" --output-format json`.
#   - num_turns=0, total_cost_usd=0 -> the slash command is handled locally with no
#     model call, so collecting costs zero tokens/usage.
# Actual .result format (2026-07, claude 2.1.216):
#   You are currently using your subscription to power your Claude Code usage
#
#   Current session: 9% used · resets Jul 21 at 6:40pm (Asia/Seoul)
#   Current week (all models): 24% used · resets Jul 26 at 4am (Asia/Seoul)
#   Current week (Fable): 0% used        <- model label is dynamic (Opus/Fable/...), reset may be absent
set -uo pipefail

DIR="$HOME/.claude-usage"
OUT="$DIR/usage.json"
TMP="$(mktemp "${TMPDIR:-/tmp}/claude-usage.XXXXXX")"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
[[ -x "$CLAUDE_BIN" ]] || CLAUDE_BIN="$(command -v claude || echo claude)"

mkdir -p "$DIR"
# launchd runs with the working directory set to '/'. Launching claude from there makes it
# scan /Volumes (including network mounts), triggering a macOS "network volume access" prompt.
# Pin to a local directory to avoid it.
cd "$DIR" 2>/dev/null || cd "$HOME" || true

# Reset-time string -> epoch (seconds). Empty string on failure.
#   Input e.g.: "Jul 21 at 6:40pm (Asia/Seoul)" / "Jul 26 at 4am (Asia/Seoul)"
#   The ko_KR locale can't read %b (Jul), so force LC_ALL=C.
to_epoch() {
  local s="$1" tz="" body fmt yr ep now
  [[ -n "$s" ]] || { echo ""; return; }
  [[ "$s" =~ \(([^\)]+)\)[[:space:]]*$ ]] && tz="${BASH_REMATCH[1]}"
  body="$(printf '%s' "$s" | sed 's/ *([^)]*)[[:space:]]*$//')"
  [[ "$body" == *:* ]] && fmt="%b %d at %I:%M%p %Y" || fmt="%b %d at %I%p %Y"
  local pfx=(env LC_ALL=C); [[ -n "$tz" ]] && pfx+=(TZ="$tz")
  yr="$("${pfx[@]}" date +%Y)"
  ep="$("${pfx[@]}" date -j -f "$fmt" "$body $yr" +%s 2>/dev/null)" || { echo ""; return; }
  now="$(date +%s)"
  # Roll to next year only for the Dec->Jan boundary (time far in the past, >40 days),
  # NOT for a reset that just elapsed a few minutes ago (which would wrongly show ~364d).
  (( ep < now - 3456000 )) && ep="$("${pfx[@]}" date -j -f "$fmt" "$body $((yr+1))" +%s 2>/dev/null)"
  echo "${ep:-}"
}

fail() {
  # Collection/parse failed: keep the last successful values, only refresh the error flag.
  local reason="$1"
  if [[ -f "$OUT" ]]; then
    jq --arg r "$reason" --arg t "$(date -u +%FT%TZ)" \
      '.error=$r | .checked_at=$t' "$OUT" > "$TMP" 2>/dev/null \
      && mv "$TMP" "$OUT"
  else
    printf '{"error":"%s","checked_at":"%s"}\n' "$reason" "$(date -u +%FT%TZ)" > "$OUT"
  fi
  rm -f "$TMP" 2>/dev/null || true
  exit 0
}

# Collect raw output (stdout only; keep stderr separate so it can't corrupt the JSON).
RAW="$("$CLAUDE_BIN" -p "/usage" --output-format json 2>/dev/null < /dev/null || true)"
[[ -n "$RAW" ]] || fail "no_output"

# Strip ANSI escapes, then extract the .result text.
CLEAN="$(printf '%s' "$RAW" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')"
TEXT="$(printf '%s' "$CLEAN" | jq -r '.result // empty' 2>/dev/null)"
[[ -n "$TEXT" ]] || fail "parse_result_failed"

# Extract fields.
S_PCT="$(printf '%s\n' "$TEXT"   | sed -n 's/^Current session: \([0-9]*\)% used.*$/\1/p' | head -1)"
S_RESET="$(printf '%s\n' "$TEXT" | sed -n 's/^Current session: [0-9]*% used · resets \(.*\)$/\1/p' | head -1)"
W_PCT="$(printf '%s\n' "$TEXT"   | sed -n 's/^Current week (all models): \([0-9]*\)% used.*$/\1/p' | head -1)"
W_RESET="$(printf '%s\n' "$TEXT" | sed -n 's/^Current week (all models): [0-9]*% used · resets \(.*\)$/\1/p' | head -1)"
M_LINE="$(printf '%s\n' "$TEXT"  | grep 'Current week' | grep -v 'all models' | head -1)"
M_LABEL="$(printf '%s\n' "$M_LINE" | sed -n 's/^Current week (\([^)]*\)):.*$/\1/p')"
M_PCT="$(printf '%s\n' "$M_LINE"   | sed -n 's/^Current week ([^)]*): \([0-9]*\)% used.*$/\1/p')"

# If neither session nor weekly number is present, treat it as failure (format change detector).
[[ -n "$S_PCT" || -n "$W_PCT" ]] || fail "no_numbers"

# Also store reset times as absolute epochs so the app can compute remaining time live.
S_EPOCH="$(to_epoch "$S_RESET")"
W_EPOCH="$(to_epoch "$W_RESET")"

jq -n \
  --argjson s_pct   "${S_PCT:-null}" \
  --arg     s_reset "${S_RESET:-}" \
  --argjson s_epoch "${S_EPOCH:-null}" \
  --argjson w_pct   "${W_PCT:-null}" \
  --arg     w_reset "${W_RESET:-}" \
  --argjson w_epoch "${W_EPOCH:-null}" \
  --arg     m_label "${M_LABEL:-}" \
  --argjson m_pct   "${M_PCT:-null}" \
  --arg     ts      "$(date -u +%FT%TZ)" \
  '{
     session_pct:            $s_pct,
     session_reset:          ($s_reset  | select(. != "")),
     session_reset_epoch:    $s_epoch,
     weekly_all_pct:         $w_pct,
     weekly_all_reset:       ($w_reset  | select(. != "")),
     weekly_all_reset_epoch: $w_epoch,
     weekly_model_label:     ($m_label | select(. != "")),
     weekly_model_pct:       $m_pct,
     error:                  null,
     collected_at:           $ts,
     checked_at:             $ts
   }' > "$TMP" 2>/dev/null || fail "encode_failed"

mv "$TMP" "$OUT"
