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
  <key>CFBundleShortVersionString</key><string>1.3</string>
  <key>CFBundleVersion</key><string>13</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 用 AppIcon.png 產生 macOS 圖示（sips 和 iconutil 都是系統內建工具）
if [ -f AppIcon.png ]; then
  ICONSET="build/AppIcon.iconset"
  mkdir -p "$ICONSET" "$APP/Contents/Resources"
  for s in 16 32 128 256 512; do
    sips -z $s $s AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --deep --sign - "$APP"

pkill -x MemBar 2>/dev/null || true
rm -rf /Applications/MemBar.app
cp -R "$APP" /Applications/
# 只讓系統認得「應用程式」裡的版本，build 裡的副本不登記，免得顯示到舊圖示
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -u "$PWD/$APP" 2>/dev/null || true
# 暫存的 build 副本用完就刪，系統只會認得「應用程式」裡那一份
rm -rf build
"$LSREG" -f /Applications/MemBar.app 2>/dev/null || true
echo "完成，已安裝到 /Applications/MemBar.app"
open /Applications/MemBar.app
