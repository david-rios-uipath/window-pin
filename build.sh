#!/bin/bash
set -e
cd "$(dirname "$0")"

BINARY="WinTop.app/Contents/MacOS/WinTop"
SOURCE="wintop.swift"

# Only recompile if source is newer than binary
if [ ! -f "$BINARY" ] || [ "$SOURCE" -nt "$BINARY" ]; then
    echo "🔨 Compiling..."
    swiftc "$SOURCE" \
      -o "$BINARY" \
      -framework Cocoa \
      -framework Carbon \
      -framework ScreenCaptureKit \
      -framework AVFoundation \
      -framework ApplicationServices

    mkdir -p WinTop.app/Contents/Resources
    cp pin.svg pin-off.svg WinTop.app/Contents/Resources/

    echo "✍️  Signing..."
    SIGN_ID=$(security find-identity -v -p codesigning | grep -q "WinTop Dev" && echo "WinTop Dev" || echo "-")
    codesign --force --deep --sign "$SIGN_ID" WinTop.app
    echo "✅ Build complete."
else
    echo "⏭️  No changes, skipping compile."
fi

echo "🚀 Restarting WinTop..."
pkill -x WinTop 2>/dev/null || true
sleep 0.5
rm -rf /Applications/WinTop.app
cp -R WinTop.app /Applications/
open /Applications/WinTop.app
