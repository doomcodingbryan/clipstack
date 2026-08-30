#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

swiftc -O Store.swift test.swift -o /tmp/clipstack-test && /tmp/clipstack-test

APP="Clipstack.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O main.swift Store.swift -o "$APP/Contents/MacOS/Clipstack"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Clipstack</string>
  <key>CFBundleExecutable</key>        <string>Clipstack</string>
  <key>CFBundleIdentifier</key>        <string>local.clipstack</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
  <key>LSUIElement</key>               <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" 2>/dev/null || true
echo "Built $APP — open it with:  open $APP"
