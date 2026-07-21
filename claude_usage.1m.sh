#!/usr/bin/env bash
# <swiftbar.title>Claude Usage</swiftbar.title>
# <swiftbar.version>1.0</swiftbar.version>
# <swiftbar.desc>Claude 구독 사용량(세션/주간)을 메뉴바에 표시</swiftbar.desc>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
#
# 캐시 파일(~/.claude-usage/usage.json)만 읽으므로 가볍고 즉각적이다.
# 데이터는 launchd 데몬(collect.sh)이 5분마다 갱신한다.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

F="$HOME/.claude-usage/usage.json"

if [[ ! -f "$F" ]]; then
  echo "-- %"
  echo "---"
  echo "데이터 없음 (데몬 미실행?) | color=red"
  echo "collect.sh 지금 실행 | bash='$HOME/.claude-usage/collect.sh' terminal=false refresh=true"
  exit 0
fi

# 임계값에 따른 색상: 80%+ 빨강, 60~79% 주황
color_for() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || { echo ""; return; }
  if   (( p >= 80 )); then echo "red"
  elif (( p >= 60 )); then echo "orange"
  else echo ""; fi
}
colorpipe() { local c; c="$(color_for "$1")"; [[ -n "$c" ]] && echo "color=$c"; }

# 리셋 시각 문자열 -> 남은 시간.
#   입력 예: "Jul 21 at 6:40pm (Asia/Seoul)"  또는 "Jul 26 at 4am (Asia/Seoul)"
#   style=long  -> "3시간 25분 남음" / "2일 4시간 남음"
#   style=short -> "3h25m" / "2d4h"  (메뉴바용)
remaining() {
  local s="$1" style="${2:-long}"
  [[ -n "$s" && "$s" != "?" ]] || { echo ""; return; }
  local tz="" body="$s"
  if [[ "$s" =~ \(([^\)]+)\)[[:space:]]*$ ]]; then
    tz="${BASH_REMATCH[1]}"
    body="$(printf '%s' "$s" | sed 's/ *([^)]*)[[:space:]]*$//')"
  fi
  # 시각에 분이 있으면 %I:%M%p, 없으면 %I%p
  local fmt; [[ "$body" == *:* ]] && fmt="%b %d at %I:%M%p %Y" || fmt="%b %d at %I%p %Y"
  # 시스템 로케일(ko_KR)에선 %b(Jul)를 못 읽으므로 LC_ALL=C 고정
  local dpfx=(env LC_ALL=C); [[ -n "$tz" ]] && dpfx+=(TZ="$tz")
  local yr epoch now
  yr="$("${dpfx[@]}" date +%Y)"
  epoch="$("${dpfx[@]}" date -j -f "$fmt" "$body $yr" +%s 2>/dev/null)" || { echo ""; return; }
  now="$(date +%s)"
  # 연말 경계: 파싱값이 과거면 내년으로 재계산
  if (( epoch < now )); then
    epoch="$("${dpfx[@]}" date -j -f "$fmt" "$body $((yr+1))" +%s 2>/dev/null)" || { echo ""; return; }
  fi
  local diff=$(( epoch - now ))
  (( diff <= 0 )) && { echo "곧 리셋"; return; }
  local d=$(( diff/86400 )) h=$(( (diff%86400)/3600 )) m=$(( (diff%3600)/60 ))
  if [[ "$style" == short ]]; then
    if   (( d > 0 )); then echo "${d}d${h}h"
    elif (( h > 0 )); then echo "${h}h${m}m"
    else echo "${m}m"; fi
  else
    if   (( d > 0 )); then echo "${d}일 ${h}시간 남음"
    elif (( h > 0 )); then echo "${h}시간 ${m}분 남음"
    else echo "${m}분 남음"; fi
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

# 리셋까지 남은 시간 계산
SREM="$(remaining "$SR" long)"    # 세션(일일) 남은시간, 드롭다운용
SREMC="$(remaining "$SR" short)"  # 세션 남은시간, 메뉴바 압축표기
WREM="$(remaining "$WR" long)"    # 주간 남은시간

# 메뉴바 한 줄 (세션 % 기준으로 색상). d=세션(일일), w=주간
BAR="d${S}% · w${W}%"
[[ -n "$SREMC" ]] && BAR="$BAR · ⏳${SREMC}"
BARCOLOR="$(color_for "$S")"
if [[ -n "$BARCOLOR" ]]; then
  echo "$BAR | color=$BARCOLOR"
else
  echo "$BAR"
fi

echo "---"
[[ -n "$ERR" ]] && echo "⚠️ 마지막 수집 실패: $ERR (아래는 마지막 성공값) | color=red"
echo "세션: ${S}% 사용 · ${SREM:-리셋 $SR} $([[ -n "$SREM" ]] && echo "(리셋 $SR)") | $(colorpipe "$S")"
echo "주간(전체): ${W}% 사용 · ${WREM:-리셋 $WR} $([[ -n "$WREM" ]] && echo "(리셋 $WR)") | $(colorpipe "$W")"
echo "주간(${ML}): ${MP}%"
echo "---"
echo "갱신: ${CA}"
echo "지금 새로고침 | bash='$HOME/.claude-usage/collect.sh' terminal=false refresh=true"
echo "Claude 앱 Usage 열기 | href=https://claude.ai/settings/usage"
