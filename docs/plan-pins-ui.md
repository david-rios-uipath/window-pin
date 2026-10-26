# Plan: "Pins" management window

Status: proposed, not implemented. Produced 2026-10-26.

## Goal

A native window, opened from the menu bar (and optionally a hotkey), that shows window thumbnails with title and app name in two sections: **Pinned** and **Recently pinned**. No listing of arbitrary unpinned windows.

## Verified facts

- `import SwiftUI` + `NSHostingView(rootView:)` typechecks with plain `swiftc` (Swift 6.3.3, macOS 26.7, no Xcode).
- Do not add `-parse-as-library` or `@main`: the file ends with top-level code (`app.run()`), and `-parse-as-library` fails with "expressions are not allowed at the top level".
- If the file is ever split, top-level code must move to `main.swift`, build.sh must compile `*.swift` with `-framework SwiftUI`, and the staleness check must cover all sources. Recommendation: stay in one file (about +200 lines); split only past that.
- Existing code: `WindowPinManager.mirrors: [MirrorPanel]`, mutated in `pinFrontmost`, `unpinWindow`, `unpinLast`, `unpinAll`. `MirrorPanel.focusRealWindow()` is private. `findFrontmostSCWindow` fetches `SCShareableContent` synchronously with a semaphore (do not copy that pattern). Carbon hotkeys use ids 1 and 2.

## 1. Data model

```swift
struct PinRecord: Codable, Identifiable {
    var id: CGWindowID { windowID }
    let windowID: CGWindowID
    var title: String
    let appName: String
    let bundleID: String?
    let pid: pid_t
    var lastPinned: Date
    var lastUnpinned: Date?   // nil while pinned
}
```

- `WindowPinManager.records: [PinRecord]`, most recent first. Thumbnails are not in the struct; they live at `thumbs/<windowID>.png` and load lazily.
- Pinned section = `mirrors`, joined to records by windowID, with live title and thumbnail.
- Recent section = records whose windowID is not in `mirrors`, sorted by `lastUnpinned` desc, capped at 8. Evicted records delete their PNG.
- Hooks: `pinFrontmost` upserts the record and clears `lastUnpinned`. `unpinWindow` / `unpinLast` / `unpinAll` set `lastUnpinned`, save a final thumbnail, then persist. `unpinWindow` already covers the window-closed and app-quit paths.
- Persistence: JSON at `~/Library/Application Support/WindowPin/recent.json`, written on change, read at launch. Thumbnails as ~320 px PNGs next to it (~30 KB each, 8 max).
- CGWindowIDs are not stable across relaunch or reboot. Validate records on load (section 5); show failures disabled rather than trusting the ID.

## 2. Titles

- `SCWindow.title` is a snapshot and goes stale. Primary source for live pins: AX `kAXTitleAttribute` on `MirrorPanel.axWin`. Add `var liveTitle: String { axTitle() ?? scWindow.title ?? appName }`.
- No observers or timers for titles. Read on UI open and on each refresh tick; write the latest title into the record at unpin time. `kAXTitleChangedNotification` is an optional later addition.
- Recents show the stored title.

## 3. Thumbnails

- API: `SCScreenshotManager.captureImage(contentFilter:configuration:)` (macOS 14+). Filter `SCContentFilter(desktopIndependentWindow:)`, config width ~320 with aspect-preserving height, `showsCursor = false`, `scalesToFit = true`. One GPU-side capture, no per-frame CPU work, no interference with the live stream.
- Rejected: `CGWindowListCreateImage` (obsoleted in macOS 15); tapping `didOutputSampleBuffer` (reintroduces the per-frame cost that was removed).
- Cadence: capture all pinned on open, then a 2 s `Timer` only while the window is visible; invalidate on close. Guard with `windowOcclusionState`.
- Always capture a final thumbnail before `stop()` in the unpin paths; keep `[CGWindowID: NSImage]` in memory as fallback for `didStopWithError`.
- On failure (window gone, minimized, other Space, protected): keep previous thumbnail or show a placeholder. No retries.

## 4. UI

- SwiftUI hosted in AppKit via `NSHostingView`. Add `-framework SwiftUI` to build.sh.
- Window: regular titled `NSWindow` (needs key focus for keyboard and buttons), `[.titled, .closable, .fullSizeContentView]`, transparent titlebar, `isReleasedWhenClosed = false`. One shared lazy instance; reopening orders it front. Call `NSApp.activate()` then `makeKeyAndOrderFront`.
- Level must be above `.floating` (e.g. `.floating + 1` or `.modalPanel`) or pinned mirrors will cover it.
- Size: width 640, height from `fittingSize` clamped 220 to 70% of screen, inside a `ScrollView`.
- Layout: `LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)])`. Card: 16:10 thumbnail, rounded 8, 1 px stroke; app icon 16 px (`NSRunningApplication(processIdentifier:).icon`), title `.lineLimit(1)` `.truncationMode(.middle)`, app name `.secondary`. Section headers hidden when empty. Empty state: "No pinned windows. Press ⌥P."
- Actions: pinned card has Unpin and Bring to front (hover buttons + context menu; click = bring to front). Recent card has Pin again, disabled and dimmed when unavailable.
- Keyboard: `@State var selection: CGWindowID?`. Safer route than SwiftUI grid focus: wrap the hosting view in an `NSView` subclass overriding `keyDown` for arrows / Return / Esc / Delete and forward to the model.
- Dark mode: semantic colors and `.regularMaterial` background.
- State: one `ObservableObject` `PinsModel` with `@Published pinned` and `recent`; `reload()` from the manager on open, tick, and after actions. Do not make `WindowPinManager` observable.

## 5. Re-pin flow

- `WindowPinManager.pin(windowID:)`, async: fetch `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)` (async API), look up the ID, verify `owningApplication?.processID == record.pid` or bundle id match, then create `MirrorPanel`, append, start, upsert record. On miss: HUD "Window no longer exists" and drop the record.
- Extract the tail of `pinFrontmost` into `private func pin(_ scWindow: SCWindow)` and call it from both paths. Only meaningful change to existing code.
- Availability for the disabled state: one `SCShareableContent` fetch on UI open, `Set(windows.map(\.windowID))`.
- Make `focusRealWindow()` non-private for Bring to front.

## 6. Integration points

- Menu: "Show Pins…" above Quit, selector `showPins` on `AppDelegate`. No activation delay needed.
- Hotkey: `(0x0D, UInt32(optionKey), 3)` for ⌥W plus a handler branch. Same conflict class as ⌥P/⌥U (types ∑).
- Activation side effect: with WindowPin active, every mirror flips to clickable. On close, re-activate the previously frontmost app (remember `NSWorkspace.shared.frontmostApplication` before opening).
- Files: `WindowPin.swift`, `build.sh`, README feature bullet. `MirrorPanel` gains `liveTitle`, `appName`/`bundleID` accessors, and public `focusRealWindow`.

## 7. Ordered steps (each builds and runs alone)

1. build.sh `-framework SwiftUI`; `PinsModel` stub; empty SwiftUI `Text("Pins")` in an `NSWindow` from a new "Show Pins…" menu item. Test: window opens above any pinned mirror.
2. `PinRecord`, `records`, `persist()`/`load()`; hook the four mutation points. Test: pin, unpin, `cat ~/Library/Application\ Support/WindowPin/recent.json` shows `lastUnpinned`.
3. Pinned-only grid with icon, `liveTitle`, app name, placeholder thumbnail. Test: pin two windows, retitle a browser tab, reopen, title updates.
4. Thumbnails via `SCScreenshotManager` on open + 2 s timer while visible. Test: thumbnails match; CPU ~0% after closing.
5. Card actions: Unpin, Bring to front, ⌫ / Return / Esc. Test: Unpin removes card and mirror.
6. Recents: final PNG on unpin, cap 8 with cleanup, load on launch. Test: pin/unpin 10, 8 remain, survive relaunch.
7. Re-pin: extract `pin(_:)`, add `pin(windowID:)` with identity check and HUD on failure. Test: unpin then Pin again recreates the mirror; closed window shows disabled or drops.
8. Keyboard navigation + ⌥W hotkey. Test: ⌥W opens, arrows move, Return acts, Esc closes.
9. Polish: empty state, dark mode, README bullet, stop timer when occluded.

## 8. Risks and open questions

- Window ID reuse across relaunch. Mitigation: pid + bundle id check and validate-on-load. Fuzzy re-pin (bundle + title) is a follow-up.
- Mirrors covering the management window: set level above `.floating`, verify with overlapping pins.
- `SCScreenshotManager` failures for minimized / other-Space / protected windows: placeholder, no retries.
- Screen Recording grant is shared; no new prompt.
- Swift 6 concurrency: stays in language mode 5; keep UI mutation on the main actor; do not enable strict concurrency.
- Single-file growth to ~750 lines. Split to `PinsUI.swift` + `main.swift` if it hurts.
- **Open:** should recents persist across relaunch/reboot (recommended, ~40 lines) or be session-only?
- **Open:** ⌥W hotkey, or menu-only?
- **Open:** unavailable recents greyed until first re-pin attempt then dropped (recommended), or dropped immediately?
