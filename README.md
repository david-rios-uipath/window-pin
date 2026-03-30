# WinTop 📌

[中文文档](./README_CN.md) | English


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

- **⌥ + P** — Pin the current frontmost window
- **⌥ + U** — Unpin the most recently pinned window
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
git clone https://github.com/YOUR_USERNAME/WinTop.git
cd WinTop
chmod +x build.sh
./build.sh
```

`build.sh` compiles the Swift source, signs the app with an ad-hoc signature, and launches WinTop. The app will appear in your menu bar as 📌.

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
| Mirror is read-only | The floating window is a live visual copy, not a true window proxy |
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

- [Topit](https://github.com/lihaoyun6/Topit) — ScreenCaptureKit mirror approach
- [AlwaysOnTop](https://github.com/AirBalloonDev/AlwaysOnTop) — hotkey and window manager patterns

## License

MIT
