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

    echo "✍️  Signing..."
    codesign --force --deep --sign - WinTop.app
    echo "✅ Build complete."
else
    echo "⏭️  No changes, skipping compile."
fi

echo "🚀 Restarting WinTop..."
pkill -x WinTop 2>/dev/null || true
sleep 0.5
open WinTop.app
