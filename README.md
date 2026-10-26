# WinTop 📌

[中文文档](./README_CN.md) | English

> Fork of [iconoclas/Mac-Window-Pin](https://github.com/iconoclas/Mac-Window-Pin) by icos. All credit for the original ScreenCaptureKit mirror design goes to the upstream author. This fork adds clickable menu items, click-to-refocus, per-display capture scale, drag/resize sync improvements, and Lucide icons.


A lightweight macOS utility that keeps any window visually on top — without stealing focus.

## How It Works

WinTop uses **ScreenCaptureKit** to create a floating mirror of the target window. The mirror panel sits above all other windows at the floating level, while the real window remains wherever it is in the z-order. The original window retains focus, keyboard input, and full interactivity — WinTop's overlay passes all mouse events through to the real window.

```
┌─────────────────────────────────┐
│  WinTop Mirror Panel (.floating)│  ← always visible on top
│  [live SCStream render]         │  ← ignoresMouseEvents = true
└─────────────────────────────────┘
         ↕ passes through all mouse/keyboard events
┌─────────────────────────────────┐
│  Real Window (normal z-order)   │  ← still fully interactive
└─────────────────────────────────┘
```

## Features

- **⌥ + P** — Pin the current frontmost window (also in the menu bar menu)
- **⌥ + U** — Unpin the most recently pinned window (also in the menu bar menu)
- **Click the mirror** when another app is active to bring the real window back to front
- Capture resolution follows the display the window is on
- Pin **multiple windows** simultaneously
- Mirror follows the window when moved or resized
- No focus stealing — your typing is never interrupted
- Menu bar icon with Quit

## System Requirements

| Item | Requirement |
|---|---|
| macOS | **macOS 14 Sonoma or later** (ScreenCaptureKit `SCContentFilter(desktopIndependentWindow:)` requires macOS 14+) |
| Architecture | Apple Silicon and Intel |
| Permissions | **Accessibility** + **Screen Recording** (both required) |
| Swift | Swift 5.9+ (Xcode 15+) or command-line tools |

> Tested on macOS 15 Sequoia and macOS 26 Tahoe.

## Installation

### Build from source (recommended)

```bash
git clone https://github.com/david-rios-uipath/window-pin.git
cd window-pin
./build.sh
```

`build.sh` compiles the Swift source, signs the app, copies it to `/Applications`, and launches it. The app appears in your menu bar as a pin icon.

#### Stable code signing (recommended)

macOS ties Accessibility and Screen Recording grants to the app's code signature. The default ad-hoc signature changes on every rebuild, so you would be re-prompted after each build. To avoid that, create a self-signed code-signing certificate once:

1. Keychain Access → Certificate Assistant → Create a Certificate
2. Name `WinTop Dev`, Identity Type **Self Signed Root**, Certificate Type **Code Signing**
3. Double-click the new cert → Trust → Code Signing: **Always Trust**

`build.sh` signs with `WinTop Dev` if it exists and falls back to ad-hoc otherwise.

On first launch, macOS will ask for:
1. **Accessibility access** — required to identify the frontmost window
2. **Screen Recording access** — required by ScreenCaptureKit to capture the window

Grant both in **System Settings → Privacy & Security**.

> **Note:** If you rebuild after modifying the source, run `./build.sh` again. The script only recompiles when `wintop.swift` is newer than the binary, and re-signs to avoid re-authorization prompts.

## Usage

1. Launch `WinTop.app` (or run `./build.sh`)
2. Click on the window you want to keep on top
3. Press **⌥ + P** (Option + P) — a floating mirror appears
4. Switch to other apps — the mirror stays visible on top
5. Press **⌥ + U** (Option + U) to unpin (repeatable for multiple pinned windows)

## Known Limitations

| Limitation | Reason |
|---|---|
| ~1 frame drag lag | Mirror renders via SCStream capture pipeline (not direct compositing); inherent to the approach |
| Requires Screen Recording permission | ScreenCaptureKit TCC requirement on macOS 14+ |
| Mirror is read-only | The floating window is a live visual copy; clicking it refocuses the real window rather than interacting with the copy |
| No minimize/maximize controls | By design — the mirror is a borderless overlay |

## Architecture

```
wintop.swift
├── CaptureManager      — SCStream setup, frame delivery, dynamic resolution update
├── MirrorPanel         — NSPanel overlay, AXObserver for position sync, layer stack
├── WinTopManager       — Manages array of active mirrors, pin/unpin logic
└── AppDelegate         — Menu bar, Carbon hotkey registration, TCC permission request
```

**Key design choices:**
- `SCContentFilter(desktopIndependentWindow:)` — captures a single window without capturing the whole screen
- `AVSampleBufferDisplayLayer` + static fallback `CALayer` — prevents black flash during compositing
- `AXObserver` (`kAXWindowMovedNotification` / `kAXWindowResizedNotification`) — event-driven position sync with zero polling overhead when idle
- `panel.ignoresMouseEvents = true` — all input passes through to the real window
- `panel.level = .floating` + `.nonactivatingPanel` — stays above normal windows without participating in focus management

## Inspired By

- [Mac-Window-Pin](https://github.com/iconoclas/Mac-Window-Pin) — the original project this fork is based on
- [Topit](https://github.com/lihaoyun6/Topit) — ScreenCaptureKit mirror approach
- [AlwaysOnTop](https://github.com/AirBalloonDev/AlwaysOnTop) — hotkey and window manager patterns

## Similar Projects

- [Topit](https://github.com/lihaoyun6/Topit) — mature, App Store-quality window pinner using the same ScreenCaptureKit mirror approach. If you want a polished, signed app rather than a build-it-yourself tool, start there.

## License

MIT — see [LICENSE](./LICENSE). Original work © icos (iconoclas); modifications © David Rios.

Icons: [Lucide](https://lucide.dev) (ISC license).
