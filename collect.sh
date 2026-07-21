#!/usr/bin/env bash
# Claude 사용량 수집 데몬.
# 경로 A (STEP 0에서 확정): `claude -p "/usage" --output-format json` 의 .result 텍스트를 파싱.
#   - num_turns=0, total_cost_usd=0 → 모델 호출 없이 슬래시 명령이 직접 처리되어 사용량 소모가 없다.
# 실제 .result 형식 (2026-07, claude 2.1.216):
#   You are currently using your subscription to power your Claude Code usage
#
#   Current session: 9% used · resets Jul 21 at 6:40pm (Asia/Seoul)
#   Current week (all models): 24% used · resets Jul 26 at 4am (Asia/Seoul)
#   Current week (Fable): 0% used        <- 모델 라벨은 동적(Opus/Fable 등), reset 없을 수 있음
set -uo pipefail

DIR="$HOME/.claude-usage"
OUT="$DIR/usage.json"
TMP="$(mktemp "${TMPDIR:-/tmp}/claude-usage.XXXXXX")"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
[[ -x "$CLAUDE_BIN" ]] || CLAUDE_BIN="$(command -v claude || echo claude)"

mkdir -p "$DIR"
# launchd 는 작업 디렉토리가 '/' 라, 여기서 claude 를 띄우면 /Volumes(네트워크 마운트 포함)를
# 스캔하며 macOS 권한 프롬프트("네트워크 볼륨 접근")가 뜬다. 로컬 폴더로 고정해 방지.
cd "$DIR" 2>/dev/null || cd "$HOME" || true

# 리셋 시각 문자열 -> epoch(초). 실패 시 빈 문자열.
#   입력 예: "Jul 21 at 6:40pm (Asia/Seoul)" / "Jul 26 at 4am (Asia/Seoul)"
#   ko_KR 로케일에선 %b(Jul)를 못 읽으므로 LC_ALL=C 고정.
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
  (( ep < now )) && ep="$("${pfx[@]}" date -j -f "$fmt" "$body $((yr+1))" +%s 2>/dev/null)"
  echo "${ep:-}"
}

fail() {
  # 수집/파싱 실패: 마지막 성공값을 유지하고 에러 플래그만 갱신.
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

# 원시 출력 수집 (stdout만; stderr 분리해 JSON 오염 방지)
RAW="$("$CLAUDE_BIN" -p "/usage" --output-format json 2>/dev/null < /dev/null || true)"
[[ -n "$RAW" ]] || fail "no_output"

# ANSI 이스케이프 제거 후 .result 텍스트 추출
CLEAN="$(printf '%s' "$RAW" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')"
TEXT="$(printf '%s' "$CLEAN" | jq -r '.result // empty' 2>/dev/null)"
[[ -n "$TEXT" ]] || fail "parse_result_failed"

# 필드 추출
S_PCT="$(printf '%s\n' "$TEXT"   | sed -n 's/^Current session: \([0-9]*\)% used.*$/\1/p' | head -1)"
S_RESET="$(printf '%s\n' "$TEXT" | sed -n 's/^Current session: [0-9]*% used · resets \(.*\)$/\1/p' | head -1)"
W_PCT="$(printf '%s\n' "$TEXT"   | sed -n 's/^Current week (all models): \([0-9]*\)% used.*$/\1/p' | head -1)"
W_RESET="$(printf '%s\n' "$TEXT" | sed -n 's/^Current week (all models): [0-9]*% used · resets \(.*\)$/\1/p' | head -1)"
M_LINE="$(printf '%s\n' "$TEXT"  | grep 'Current week' | grep -v 'all models' | head -1)"
M_LABEL="$(printf '%s\n' "$M_LINE" | sed -n 's/^Current week (\([^)]*\)):.*$/\1/p')"
M_PCT="$(printf '%s\n' "$M_LINE"   | sed -n 's/^Current week ([^)]*): \([0-9]*\)% used.*$/\1/p')"

# 세션/주간 수치 둘 다 없으면 실패로 간주(형식 변경 감지)
[[ -n "$S_PCT" || -n "$W_PCT" ]] || fail "no_numbers"

# 리셋 시각을 절대시각(epoch)으로도 저장 → 앱이 남은시간을 실시간 계산
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
