#!/bin/bash
# 編譯 MemBar 並打包成 .app，再複製到「應用程式」資料夾
set -e
cd "$(dirname "$0")"

APP="build/MemBar.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "找不到 swiftc，請先執行：xcode-select --install"
  exit 1
fi

ARCH="$(uname -m)"
echo "編譯中 (${ARCH})..."
swiftc -O -parse-as-library \
  -target "${ARCH}-apple-macos13.0" \
  Sources/main.swift \
  -o "$APP/Contents/MacOS/MemBar"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MemBar</string>
  <key>CFBundleDisplayName</key><string>MemBar</string>
  <key>CFBundleIdentifier</key><string>local.membar</string>
  <key>CFBundleExecutable</key><string>MemBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"

pkill -x MemBar 2>/dev/null || true
rm -rf /Applications/MemBar.app
cp -R "$APP" /Applications/
echo "完成，已安裝到 /Applications/MemBar.app"
open /Applications/MemBar.app
