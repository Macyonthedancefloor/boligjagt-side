#!/bin/bash
# Bygger Boligjagt.app. Kraever kun Command Line Tools, ikke hele Xcode.
#
#   ./byg.sh            bygger til mac/build/Boligjagt.app
#   ./byg.sh /Applications   bygger og lægger den i Programmer
#
set -euo pipefail

HER="$(cd "$(dirname "$0")" && pwd)"
MAAL="${1:-$HER/build}"
APP="$MAAL/Boligjagt.app"

echo "Bygger Boligjagt.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# --- Info.plist -------------------------------------------------------------
# LSUIElement gør den til en ren menulinje-app uden ikon i Dock.
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Boligjagt</string>
  <key>CFBundleDisplayName</key>       <string>Boligjagt</string>
  <key>CFBundleIdentifier</key>        <string>dk.boligjagt.menubar</string>
  <key>CFBundleVersion</key>           <string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleExecutable</key>        <string>Boligjagt</string>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
  <key>LSUIElement</key>               <true/>
  <key>CFBundleIconFile</key>          <string>AppIcon</string>
  <key>NSHumanReadableCopyright</key>  <string>Personligt vaerktoej</string>
</dict>
</plist>
PLIST

# --- ikon -------------------------------------------------------------------
# Tegnes fra bunden, saa der ikke ligger billedfiler i repoet.
TMP="$(mktemp -d)"
swiftc -O -framework AppKit -o "$TMP/lavikon" "$HER/lav-ikon.swift"
"$TMP/lavikon" "$TMP/Boligjagt.iconset" > /dev/null
iconutil -c icns "$TMP/Boligjagt.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$TMP"

# --- oversaettelse ----------------------------------------------------------
swiftc -O \
  -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit -framework UserNotifications \
  -o "$APP/Contents/MacOS/Boligjagt" \
  "$HER/Boligjagt.swift"

# --- signering --------------------------------------------------------------
# Ad hoc-signering. Den koster ingenting og kraever ingen Apple-konto.
# Notifikationer virker kun paa en signeret app, ogsaa selvom signaturen er
# lokal, saa dette trin er ikke til pynt.
codesign --force --deep --sign - \
         --identifier dk.boligjagt.menubar \
         "$APP" 2>/dev/null

echo "Faerdig: $APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature" || true
