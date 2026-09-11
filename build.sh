#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
BUILD_DIR="${MACFOLD_BUILD_DIR:-${MACDUO_BUILD_DIR:-${LIDFLOW_BUILD_DIR:-.build}}}"
swift build -c release --scratch-path "$BUILD_DIR"
BIN_DIR="$(swift build -c release --scratch-path "$BUILD_DIR" --show-bin-path)"
SIGNING_IDENTITY="${MACFOLD_SIGNING_IDENTITY:-${MACDUO_SIGNING_IDENTITY:-${LIDFLOW_SIGNING_IDENTITY:-}}}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  if [[ -f signing-identity.txt ]]; then
    SIGNING_IDENTITY="$(cat signing-identity.txt)"
  else
    SIGNING_IDENTITY="-"
  fi
fi
APP="$PWD/build/Mac Fold.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MacFold" "$APP/Contents/MacOS/MacFold"
# Remove debug symbols containing local build paths before signing the app.
xcrun strip -S "$APP/Contents/MacOS/MacFold"
cp Resources/MacFoldMark.png Resources/MacFold.icns "$APP/Contents/Resources/"
cp docs/assets/mark.png "$APP/Contents/Resources/"
[[ -f ATTRIBUTION.md ]] && cp ATTRIBUTION.md "$APP/Contents/Resources/" || true
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Mac Fold</string>
<key>CFBundleDisplayName</key><string>Mac Fold</string>
<key>CFBundleIdentifier</key><string>local.lidflow.mac</string>
<key>CFBundleExecutable</key><string>MacFold</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>MacFold</string>
<key>CFBundleShortVersionString</key><string>0.1.12</string>
<key>CFBundleVersion</key><string>13</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>Mac Fold displays a temporary, animated copy of your desktop as you move the lid. Frames stay in memory on this Mac.</string>
</dict></plist>
PLIST
codesign --force --sign "$SIGNING_IDENTITY" --identifier local.lidflow.mac "$APP"
codesign --verify --strict "$APP"
plutil -lint "$APP/Contents/Info.plist"
printf 'Built %s\n' "$APP"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  printf 'Ad-hoc development build. Use a consistent Apple Development identity to preserve Screen Recording access across updates.\n'
fi
