#!/bin/zsh
# Builds UMounter.app from the SwiftPM package in App/ (no Xcode project needed).
#
#   scripts/build-app.sh            # release build → App/build/UMounter.app
#   CONFIG=debug scripts/build-app.sh
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
set -euo pipefail

ROOT=${0:A:h:h}
CONFIG=${CONFIG:-release}
SIGN_IDENTITY=${SIGN_IDENTITY:--}   # "-" = ad-hoc
APP="$ROOT/App/build/UMounter.app"
VERSION=${VERSION:-0.1.0}
BUILD=${BUILD:-$(date +%Y%m%d%H%M)}

swift build --package-path "$ROOT/App" -c "$CONFIG" --product UMounter
BIN_DIR=$(swift build --package-path "$ROOT/App" -c "$CONFIG" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/UMounter" "$APP/Contents/MacOS/UMounter"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>         <string>app.umounter.UMounter</string>
    <key>CFBundleName</key>               <string>UMounter</string>
    <key>CFBundleDisplayName</key>        <string>UMounter</string>
    <key>CFBundleExecutable</key>         <string>UMounter</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>            <string>$BUILD</string>
    <key>LSMinimumSystemVersion</key>     <string>14.0</string>
    <key>LSUIElement</key>                <true/>
    <key>LSApplicationCategoryType</key>  <string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key>   <string>© 2026 UMounter</string>
</dict>
</plist>
PLIST

codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$APP"
echo "Built $APP"
