#!/bin/bash
set -e
cd "$(dirname "$0")"

APP="WindowPin.app"
BINARY="$APP/Contents/MacOS/WindowPin"
SOURCES=(*.swift)
# Self-signed code-signing identity; falls back to ad-hoc. See README "Stable code signing".
SIGN_IDENTITY="${SIGN_IDENTITY:-WindowPin Dev}"

if [ ! -f "$BINARY" ] || [ -n "$(find "${SOURCES[@]}" -newer "$BINARY")" ]; then
    echo "🔨 Compiling..."
    mkdir -p "$(dirname "$BINARY")"
    swiftc "${SOURCES[@]}" \
      -o "$BINARY" \
      -framework Cocoa \
      -framework SwiftUI \
      -framework Carbon \
      -framework ScreenCaptureKit \
      -framework AVFoundation \
      -framework ApplicationServices
fi

mkdir -p "$APP/Contents/Resources"
cp pin.svg pin-off.svg bring-to-front.svg AppIcon.icns "$APP/Contents/Resources/"

echo "✍️  Signing..."
if security find-identity -v -p codesigning | grep -q "\"$SIGN_IDENTITY\""; then
    SIGN_ID="$SIGN_IDENTITY"
else
    echo "   (no '$SIGN_IDENTITY' identity found, using ad-hoc; permissions reset on each rebuild)"
    SIGN_ID="-"
fi
codesign --force --deep --sign "$SIGN_ID" "$APP"
echo "✅ Build complete."

echo "🚀 Restarting WindowPin..."
pkill -x WindowPin 2>/dev/null || true
sleep 0.5
rm -rf "/Applications/$APP"
cp -R "$APP" /Applications/
open "/Applications/$APP"
