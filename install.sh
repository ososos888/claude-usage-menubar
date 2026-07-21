#!/usr/bin/env bash
# Claude 사용량 메뉴바 위젯 설치 스크립트 (스탠드얼론 네이티브 앱 방식).
#   1) collect.sh 를 ~/.claude-usage 에 배치
#   2) launchd 데몬 등록(1분마다 수집)
#   3) 네이티브 메뉴바 앱(ClaudeUsageBar) 빌드·설치·자동실행 등록
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.claude-usage"
PLIST="$HOME/Library/LaunchAgents/com.user.claude-usage.plist"

echo "==> 필수 도구 확인"
command -v jq      >/dev/null || { echo "jq 가 필요합니다: brew install jq"; exit 1; }
command -v claude  >/dev/null || { echo "Claude Code(claude) 가 필요합니다: https://claude.com/claude-code"; exit 1; }
command -v swiftc  >/dev/null || { echo "Swift 컴파일러가 필요합니다: xcode-select --install"; exit 1; }

echo "==> 수집기 배치: $DEST"
mkdir -p "$DEST"
cp "$HERE/collect.sh" "$DEST/collect.sh"
chmod +x "$DEST/collect.sh"

echo "==> 최초 1회 수집"
"$DEST/collect.sh" || true

echo "==> 수집 데몬 등록 (1분 주기)"
cp "$HERE/com.user.claude-usage.plist" "$PLIST"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load  "$PLIST"

echo "==> 메뉴바 앱 빌드·설치"
"$HERE/standalone/build.sh"

cat <<'EOF'

설치 완료. 메뉴바에 'd..% · w..% · ⏳남은시간' 이 뜨면 성공입니다.
(SwiftBar 등 별도 앱 불필요. 로그인 시 자동 실행됩니다.)

SwiftBar 를 선호한다면 대신 swiftbar/README 참고.
EOF
