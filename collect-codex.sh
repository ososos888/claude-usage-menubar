#!/usr/bin/env bash
# Codex usage collector daemon (the OpenAI Codex CLI counterpart of collect.sh).
#
# Data path: the Codex CLI's app-server speaks JSON-RPC over stdio, and its
# `account/rateLimits/read` method returns the same rate-limit snapshot the TUI's /status
# renders. No thread and no turn is ever started, so collecting starts no model call:
# it costs zero tokens and — unlike `codex exec` — leaves nothing under ~/.codex/sessions.
#
# Actual response shape (2026-09, codex-cli 0.150.1):
#   {"id":2,"result":{
#      "rateLimits":{"limitId":"codex","planType":"plus",
#        "primary":  {"usedPercent":83,"windowDurationMins":300,  "resetsAt":1788952298},
#        "secondary":{"usedPercent":33,"windowDurationMins":10080,"resetsAt":1789446032}, ...},
#      "rateLimitsByLimitId":{"codex":{...}},
#      "rateLimitResetCredits":{"availableCount":2,"credits":[...]}}}
#
#   primary   = the rolling 5-hour window  -> written as session_*  (Claude's "session")
#   secondary = the weekly window          -> written as weekly_all_* (Claude's "weekly")
#
# Output keys deliberately mirror collect.sh so one parser in the app reads both providers.
# `resetsAt` is already an absolute epoch, so there is no date-string parsing here.
set -uo pipefail

DIR="$HOME/.claude-usage"
OUT="$DIR/codex-usage.json"
TMP="$(mktemp "${TMPDIR:-/tmp}/codex-usage.XXXXXX")"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
# How long to wait for the app-server response. It normally answers in ~1.5 s; the cap only
# matters when the network is down, and must stay well under the 60 s collection interval.
TIMEOUT_TICKS=75      # × 0.2 s = 15 s

mkdir -p "$DIR"
# launchd runs with the working directory set to '/'. Starting a CLI from there makes it scan
# /Volumes (including network mounts) and can trigger a macOS "network volume access" prompt.
cd "$DIR" 2>/dev/null || cd "$HOME" || true

fail() {
  # Collection failed: keep the last successful values, only refresh the error flag — same
  # contract as collect.sh, so a transient failure never blanks the display.
  local reason="$1"
  if [[ -s "$OUT" ]] && jq -e . "$OUT" >/dev/null 2>&1; then
    jq --arg r "$reason" --arg t "$(date -u +%FT%TZ)" \
      '.error=$r | .checked_at=$t' "$OUT" > "$TMP" 2>/dev/null \
      && mv "$TMP" "$OUT"
  else
    printf '{"error":"%s","checked_at":"%s"}\n' "$reason" "$(date -u +%FT%TZ)" > "$OUT"
  fi
  rm -f "$TMP" 2>/dev/null || true
  exit 0
}

# Codex is optional: this widget is Claude-first and simply hides the Codex half when the CLI
# isn't installed or nobody is signed in, rather than reporting a failure the user can't care
# about. Both states are their own error string so the app can tell them apart.
CODEX_BIN="${CODEX_BIN:-}"
if [[ -z "$CODEX_BIN" || ! -x "$CODEX_BIN" ]]; then
  for cand in "$HOME/.local/bin/codex" /opt/homebrew/bin/codex /usr/local/bin/codex; do
    [[ -x "$cand" ]] && { CODEX_BIN="$cand"; break; }
  done
fi
[[ -n "$CODEX_BIN" && -x "$CODEX_BIN" ]] || CODEX_BIN="$(command -v codex || true)"
[[ -n "$CODEX_BIN" ]] || fail "not_installed"

# Signed in? `codex login` writes ~/.codex/auth.json. Checking the file first keeps a machine
# without Codex from starting a CLI process every single minute.
[[ -s "$CODEX_HOME/auth.json" ]] || fail "logged_out"

# Ask the app-server for the snapshot. stdin is a FIFO so the requests can be written after
# the process starts; stdout is polled so we return as soon as the answer lands instead of
# sleeping a fixed amount.
# `version` identifies this collector to the app-server, not the widget release, so it does
# not move with the app's version number.
INIT_REQ='{"id":1,"method":"initialize","params":{"clientInfo":{"name":"claude-usage-menubar","title":"ClaudeUsageBar","version":"1.0.0"}}}'
LIMITS_REQ='{"id":2,"method":"account/rateLimits/read","params":null}'

probe() {
  local d in out pid i
  d="$(mktemp -d "${TMPDIR:-/tmp}/codex-usage-rpc.XXXXXX")" || return 1
  in="$d/in"; out="$d/out"
  mkfifo "$in" 2>/dev/null || { rm -rf "$d"; return 1; }
  : > "$out"
  "$CODEX_BIN" app-server --listen stdio:// < "$in" > "$out" 2>/dev/null &
  pid=$!
  exec 3>"$in"          # opening the write end unblocks the child's read
  printf '%s\n' "$INIT_REQ"   >&3
  printf '%s\n' "$LIMITS_REQ" >&3
  i=0
  while (( i < TIMEOUT_TICKS )); do
    grep -q '"id":[[:space:]]*2' "$out" 2>/dev/null && break
    sleep 0.2
    i=$(( i + 1 ))
  done
  exec 3>&-
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  grep '"id":[[:space:]]*2' "$out" 2>/dev/null | head -1
  rm -rf "$d"
}

RESP="$(probe)"
[[ -n "$RESP" ]] || fail "no_output"
jq -e . <<<"$RESP" >/dev/null 2>&1 || fail "parse_result_failed"
jq -e '.error' <<<"$RESP" >/dev/null 2>&1 && fail "rpc_error"

# Prefer the metered `codex` bucket; fall back to the flat backward-compatible view.
SNAP="$(jq -c '.result.rateLimitsByLimitId.codex // .result.rateLimits // empty' <<<"$RESP" 2>/dev/null)"
[[ -n "$SNAP" ]] || fail "no_numbers"

get() { jq -r "$1 // empty" <<<"$SNAP" 2>/dev/null; }
S_PCT="$(get '.primary.usedPercent')"
S_EPOCH="$(get '.primary.resetsAt')"
S_WIN="$(get '.primary.windowDurationMins')"
W_PCT="$(get '.secondary.usedPercent')"
W_EPOCH="$(get '.secondary.resetsAt')"
W_WIN="$(get '.secondary.windowDurationMins')"
PLAN="$(get '.planType')"
CREDITS="$(jq -r '.result.rateLimitResetCredits.availableCount // empty' <<<"$RESP" 2>/dev/null)"

# No percentages at all: credentials exist (checked above), so either the account has no
# Codex plan limits (an API-key login, say) or the payload changed shape — our bug to fix.
[[ -n "$S_PCT" || -n "$W_PCT" ]] || fail "no_numbers"

jq -n \
  --argjson s_pct   "${S_PCT:-null}" \
  --argjson s_epoch "${S_EPOCH:-null}" \
  --argjson s_win   "${S_WIN:-null}" \
  --argjson w_pct   "${W_PCT:-null}" \
  --argjson w_epoch "${W_EPOCH:-null}" \
  --argjson w_win   "${W_WIN:-null}" \
  --arg     plan    "${PLAN:-}" \
  --argjson credits "${CREDITS:-null}" \
  --arg     ts      "$(date -u +%FT%TZ)" \
  '{
     session_pct:            $s_pct,
     session_reset_epoch:    $s_epoch,
     session_window_mins:    $s_win,
     weekly_all_pct:         $w_pct,
     weekly_all_reset_epoch: $w_epoch,
     weekly_window_mins:     $w_win,
     plan:                   ($plan | select(. != "")),
     reset_credits:          $credits,
     error:                  null,
     collected_at:           $ts,
     checked_at:             $ts
   }' > "$TMP" 2>/dev/null || fail "encode_failed"

# Never overwrite with an empty/invalid file (would break the app's parse).
[[ -s "$TMP" ]] && jq -e . "$TMP" >/dev/null 2>&1 || fail "encode_empty"
mv "$TMP" "$OUT"
