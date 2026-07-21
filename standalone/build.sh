#!/usr/bin/env bash
# ClaudeUsageBar 네이티브 메뉴바 앱을 빌드해 ~/Applications 에 설치하고
# 로그인 시 자동 실행되도록 launchd 에 등록한다. (SwiftBar 불필요)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPNAME="ClaudeUsageBar"
BUNDLE_ID="com.ososos888.claudeusagebar"
APPDIR="$HOME/Applications/$APPNAME.app"
PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

echo "==> Swift 컴파일"
BIN="$(mktemp -d)/$APPNAME"
swiftc -O -o "$BIN" "$HERE/ClaudeUsageBar.swift" -framework Cocoa

echo "==> 앱 번들 생성: $APPDIR"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/Contents/MacOS"
mv "$BIN" "$APPDIR/Contents/MacOS/$APPNAME"
chmod +x "$APPDIR/Contents/MacOS/$APPNAME"

cat > "$APPDIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APPNAME</string>
  <key>CFBundleDisplayName</key><string>Claude Usage</string>
  <key>CFBundleExecutable</key><string>$APPNAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT</string>
</dict>
</plist>
EOF

# 로컬 빌드 실행이 Gatekeeper 격리로 막히지 않도록 quarantine 속성 제거
xattr -dr com.apple.quarantine "$APPDIR" 2>/dev/null || true

echo "==> launchd 자동 실행 등록: $PLIST"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$BUNDLE_ID</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APPDIR/Contents/MacOS/$APPNAME</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo
echo "설치 완료. 메뉴바에 's..% · w..% · ⏳..' 가 표시됩니다."
echo "종료/중지: launchctl unload \"$PLIST\""
