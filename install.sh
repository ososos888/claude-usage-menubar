#!/usr/bin/env bash
# Claude 사용량 메뉴바 위젯 설치 스크립트.
#   - collect.sh / 플러그인을 ~/.claude-usage 에 배치
#   - launchd 데몬 등록(5분마다 수집)
#   - SwiftBar 플러그인 폴더(~/SwiftBarPlugins)에 심링크
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.claude-usage"
PLUGINDIR="${SWIFTBAR_PLUGIN_DIR:-$HOME/SwiftBarPlugins}"
PLIST="$HOME/Library/LaunchAgents/com.user.claude-usage.plist"

echo "==> 필수 도구 확인"
command -v jq     >/dev/null || { echo "jq 가 필요합니다: brew install jq"; exit 1; }
command -v claude >/dev/null || { echo "Claude Code(claude) 가 필요합니다: https://claude.com/claude-code"; exit 1; }

echo "==> 스크립트 배치: $DEST"
mkdir -p "$DEST"
cp "$HERE/collect.sh"           "$DEST/collect.sh"
cp "$HERE/claude_usage.1m.sh"   "$DEST/claude_usage.1m.sh"
chmod +x "$DEST/collect.sh" "$DEST/claude_usage.1m.sh"

echo "==> 최초 1회 수집"
"$DEST/collect.sh" || true

echo "==> launchd 데몬 등록 (5분 주기)"
cp "$HERE/com.user.claude-usage.plist" "$PLIST"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load  "$PLIST"

echo "==> SwiftBar 플러그인 링크: $PLUGINDIR"
mkdir -p "$PLUGINDIR"
ln -sf "$DEST/claude_usage.1m.sh" "$PLUGINDIR/claude_usage.1m.sh"

cat <<EOF

설치 완료.

남은 단계:
  1) SwiftBar 미설치 시:  brew install --cask swiftbar
  2) SwiftBar 실행 → Plugin Folder 를 '$PLUGINDIR' 로 지정
  3) (선택) SwiftBar Preferences → "Start at Login" 체크

메뉴바에 '세션% · 주 주간% · ⏳남은시간' 이 뜨면 성공입니다.
EOF
