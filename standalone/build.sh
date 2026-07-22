#!/usr/bin/env bash
# Build the ClaudeUsageBar native menu bar app, install it into ~/Applications,
# and register it with launchd to auto-start at login. (No SwiftBar required.)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPNAME="ClaudeUsageBar"
BUNDLE_ID="com.ososos888.claudeusagebar"
VERSION="1.2.0"
APPDIR="$HOME/Applications/$APPNAME.app"
PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

echo "==> Compiling Swift"
BIN="$(mktemp -d)/$APPNAME"
swiftc -O -o "$BIN" "$HERE/ClaudeUsageBar.swift" -framework Cocoa

echo "==> Creating app bundle: $APPDIR"
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
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT</string>
</dict>
</plist>
EOF

# Remove the quarantine attribute so Gatekeeper doesn't block the locally built binary.
xattr -dr com.apple.quarantine "$APPDIR" 2>/dev/null || true
# Ad-hoc sign (free, no Apple account) so notifications work and Gatekeeper is happy.
codesign --force --deep --sign - "$APPDIR" 2>/dev/null || true

echo "==> Registering launchd auto-start: $PLIST"
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
echo "Done. The menu bar should show 's..% · w..% · ⏳..'."
echo "To stop: launchctl unload \"$PLIST\""
