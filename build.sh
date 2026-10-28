#!/bin/zsh
# Xcode 없이 Command Line Tools만으로 SODADaily.app을 빌드해 ~/Applications에 설치합니다.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/SODADaily.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

SDK_ARGS=()
if [[ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk" ]]; then
  SDK_ARGS=(-sdk "/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk")
fi

swiftc "${SDK_ARGS[@]}" -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" -O \
  SODADaily/SODADailyApp.swift -o "$APP/Contents/MacOS/SODADaily"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.sodalab.SODADaily</string>
  <key>CFBundleName</key><string>SODADaily</string>
  <key>CFBundleDisplayName</key><string>SODA DAILY</string>
  <key>CFBundleExecutable</key><string>SODADaily</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>ko</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>SODA LAB</string>
  <key>NSCalendarsUsageDescription</key><string>오늘 일정을 표시하기 위해 캘린더를 읽습니다.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>오늘 일정을 표시하기 위해 캘린더를 읽습니다.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

mkdir -p ~/Applications
rm -rf ~/Applications/SODADaily.app
cp -R "$APP" ~/Applications/
echo "설치 완료: ~/Applications/SODADaily.app"
