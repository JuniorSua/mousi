#!/bin/zsh
# Builds Mousi.app into ./build and (optionally) installs it to /Applications.
#   ./build.sh            → build only
#   ./build.sh --install  → build + copy to /Applications + launch
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Mousi.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ Generating icon…"
swift Tools/MakeIcon.swift build/Mousi.iconset >/dev/null
iconutil -c icns build/Mousi.iconset -o "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Compiling…"
swiftc -O -swift-version 5 -target arm64-apple-macosx26.0 \
  -framework AppKit -framework SwiftUI -framework ApplicationServices -framework ServiceManagement \
  Sources/*.swift -o "$APP/Contents/MacOS/Mousi"

cp Info.plist "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

# Sign with a stable local identity ("Mousi Dev", a self-signed cert in its own keychain — see
# Tools/make-signing-identity.sh) so macOS keeps the Accessibility grant across rebuilds.
# Ad-hoc signatures change every build and silently invalidate it.
KC=~/Library/Keychains/mousi-dev.keychain-db
if [[ -f "$KC" ]] && security find-identity -v -p codesigning "$KC" 2>/dev/null | grep -q '"Mousi Dev"'; then
  echo "▸ Signing (Mousi Dev)…"
  codesign --force --deep --sign "Mousi Dev" --keychain "$KC" "$APP"
else
  echo "▸ Signing (ad-hoc — no 'Mousi Dev' identity found)…"
  codesign --force --deep --sign - "$APP" 2>/dev/null
fi

echo "✓ Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  echo "▸ Installing to /Applications…"
  pkill -x Mousi 2>/dev/null || true
  rm -rf /Applications/Mousi.app
  cp -R "$APP" /Applications/Mousi.app
  open /Applications/Mousi.app
  echo "✓ Mousi is running (look for it in your menu bar)."
fi
