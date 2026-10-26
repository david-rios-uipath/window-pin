import Cocoa
import Carbon
import ScreenCaptureKit
import AVFoundation

// MARK: - Screen Capture Manager (from Topit)

class CaptureManager: NSObject, SCStreamDelegate, SCStreamOutput {
    let videoLayer = AVSampleBufferDisplayLayer()
    private var stream: SCStream?
    var capturing = false
    var onError: (() -> Void)?

    // Match display refresh rate (120 on ProMotion); SCStream only emits on change so idle cost is nil
    private func makeConfig() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.capturesAudio = false
        let fps = NSScreen.main?.maximumFramesPerSecond ?? 60
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        return config
    }

    func startCapture(window: SCWindow) async throws {
        if stream != nil { return }
        let config = makeConfig()

        let filter = SCContentFilter(desktopIndependentWindow: window)
        if #available(macOS 14, *) {
            config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
            config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        } else {
            config.width = Int(window.frame.width * 2)
            config.height = Int(window.frame.height * 2)
        }

        stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global())
        try await stream?.startCapture()
        capturing = true
    }

    func stopCapture() {
        guard let s = stream else { return }
        s.stopCapture { _ in }
        stream = nil
        capturing = false
    }

    func updateCaptureSize(width: Int, height: Int) {
        guard let s = stream else { return }
        let config = makeConfig()
        config.width  = width
        config.height = height
        s.updateConfiguration(config) { err in
            if let err = err { print("[WARN] updateConfig: \(err)") }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid, outputType == .screen else { return }
        // enqueue is thread-safe; skipping the main-queue hop saves up to a frame of latency.
        // The layer keeps the last frame, so no static fallback layer is needed.
        videoLayer.enqueue(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[WARN] Capture stopped: \(error)")
        DispatchQueue.main.async {
            self.stream = nil
            self.capturing = false
            self.onError?()
        }
    }
}

// MARK: - Icons

func lucideIcon(_ name: String, size: CGFloat) -> NSImage? {
    guard let path = Bundle.main.path(forResource: name, ofType: "svg"), let img = NSImage(contentsOfFile: path) else { return nil }
    img.size = NSSize(width: size, height: size)
    img.isTemplate = true
    return img
}

// MARK: - Coordinate Transform

extension NSRect { var area: CGFloat { isNull ? 0 : width * height } }

func cgToNS(_ cgRect: CGRect) -> NSRect {
    guard let main = NSScreen.screens.first else { return cgRect }
    return NSRect(x: cgRect.origin.x,
                  y: main.frame.height - cgRect.origin.y - cgRect.height,
                  width: cgRect.width, height: cgRect.height)
}

// MARK: - Mirror Panel

class MirrorPanel {
    let scWindow: SCWindow
    let capture = CaptureManager()
    var panel: NSPanel!
    private var axObserver: AXObserver?
    private var axWin: AXUIElement?
    private var aliveTimer: Timer?    // low-freq timer just to detect window closed
    private var lastScale: CGFloat = 0
    private var resizeDebounce: DispatchWorkItem?

    init(scWindow: SCWindow) {
        self.scWindow = scWindow

        let nsFrame = cgToNS(scWindow.frame)
        panel = NSPanel(contentRect: nsFrame,
                        styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isOpaque = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // Pass-through while target app is active; otherwise click raises real window
        panel.ignoresMouseEvents = true

        let view = ClickView(frame: NSRect(origin: .zero, size: nsFrame.size))
        view.onClick = { [weak self] in self?.focusRealWindow() }
        view.wantsLayer = true
        // Clip to corner radius so no black bleed outside rounded corners
        view.layer?.cornerRadius = 10
        view.layer?.masksToBounds = true

        let videoLayer = capture.videoLayer
        videoLayer.frame = view.bounds
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(videoLayer)

        panel.contentView = view

        capture.onError = { [weak self] in
            guard let self = self else { return }
            self.stop()
            WindowPinManager.shared.unpinWindow(windowID: self.scWindow.windowID)
        }
    }

    @MainActor
    func start() async {
        panel.makeKeyAndOrderFront(nil)
        do {
            try await capture.startCapture(window: scWindow)
        } catch {
            print("[ERROR] Capture failed: \(error)")
            stop()
            return
        }
        startAXObserver()
        // Low-frequency timer only to detect if the window was closed
        aliveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkAlive()
        }
    }

    func stop() {
        resizeDebounce?.cancel()
        aliveTimer?.invalidate()
        aliveTimer = nil
        if let obs = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(obs),
                                  .defaultMode)
        }
        axObserver = nil
        capture.stopCapture()
        panel.close()
    }

    // MARK: - AXObserver

    private func startAXObserver() {
        guard let pid = scWindow.owningApplication?.processID else { return }

        // Find the matching AXUIElement window by CGWindowID
        let axApp = AXUIElementCreateApplication(pid_t(pid))
        guard let axWin = findAXWindow(axApp: axApp) else {
            print("[WARN] AXObserver: cannot find window element")
            return
        }
        self.axWin = axWin

        typealias Callback = @convention(c) (AXObserver, AXUIElement, CFString, UnsafeMutableRawPointer?) -> Void
        let cb: Callback = { _, _, notification, ptr in
            guard let ptr = ptr else { return }
            let mirror = Unmanaged<MirrorPanel>.fromOpaque(ptr).takeUnretainedValue()
            DispatchQueue.main.async { mirror.syncFrame() }
        }

        var obs: AXObserver?
        guard AXObserverCreate(pid_t(pid), cb, &obs) == .success, let observer = obs else { return }

        let ptr = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, axWin, kAXWindowMovedNotification as CFString, ptr)
        AXObserverAddNotification(observer, axWin, kAXWindowResizedNotification as CFString, ptr)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = observer
    }

    private func findAXWindow(axApp: AXUIElement) -> AXUIElement? {
        typealias GetWinFn = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError
        let fn: GetWinFn = unsafeBitCast(dlsym(dlopen(nil, RTLD_NOW), "_AXUIElementGetWindow"), to: GetWinFn.self)

        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return nil }

        for win in windows {
            var wid: CGWindowID = 0
            if fn(win, &wid) == .success, wid == scWindow.windowID { return win }
        }
        return nil
    }

    // Called by AXObserver immediately when window moves or resizes
    func syncFrame() {
        guard let cgFrame = axFrame() ?? cgWindowFrame() else { return }
        let nsFrame = cgToNS(cgFrame)

        // Scale of the display the window is mostly on; re-capture on size OR display change
        let screen = NSScreen.screens.max { $0.frame.intersection(nsFrame).area < $1.frame.intersection(nsFrame).area }
        let scale = screen?.backingScaleFactor ?? 2.0
        if panel.frame.size != nsFrame.size || scale != lastScale {
            lastScale = scale
            // Layer stretches during the drag; reconfigure capture once notifications settle
            resizeDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.capture.updateCaptureSize(width: Int(nsFrame.width * scale), height: Int(nsFrame.height * scale))
            }
            resizeDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        }
        if panel.frame != nsFrame {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            panel.setFrame(nsFrame, display: true)
            CATransaction.commit()
        }
    }

    // Position/size straight from the AX element: cheaper than CGWindowList, same coordinate space
    private func axFrame() -> CGRect? {
        guard let w = axWin else { return nil }
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeRef) == .success else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    private func cgWindowFrame() -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], scWindow.windowID) as? [[String: Any]],
              let bounds = info.first?[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        return CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
    }

    // Low-frequency check just to detect window closed
    private func checkAlive() {
        let exists = CGWindowListCopyWindowInfo([.optionIncludingWindow], scWindow.windowID) as? [[String: Any]]
        if exists?.isEmpty ?? true {
            WindowPinManager.shared.unpinWindow(windowID: scWindow.windowID)
        }
    }

    var targetPID: pid_t? { scWindow.owningApplication.map { pid_t($0.processID) } }
    var appName: String { scWindow.owningApplication?.applicationName ?? "?" }
    var bundleID: String? { scWindow.owningApplication?.bundleIdentifier }

    // AX title is live; SCWindow.title is a snapshot from pin time
    var liveTitle: String {
        var ref: CFTypeRef?
        if let w = axWin, AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &ref) == .success,
           let t = ref as? String, !t.isEmpty { return t }
        return scWindow.title.flatMap { $0.isEmpty ? nil : $0 } ?? appName
    }

    func setPassThrough(_ on: Bool) { panel.ignoresMouseEvents = on }

    func focusRealWindow() {
        guard let pid = targetPID, let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate()
        if let w = axWin { AXUIElementPerformAction(w, kAXRaiseAction as CFString) }
        setPassThrough(true)
    }
}

class ClickView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - Window Manager

class WindowPinManager {
    static let shared = WindowPinManager()
    var mirrors: [MirrorPanel] = []

    func pinFrontmost() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            print("[WARN] No frontmost app"); return
        }

        guard let scWindow = findFrontmostSCWindow(pid: frontApp.processIdentifier) else {
            print("[WARN] Cannot find SC window"); return
        }

        pin(scWindow)
    }

    func pin(_ scWindow: SCWindow) {
        if mirrors.contains(where: { $0.scWindow.windowID == scWindow.windowID }) {
            print("[WARN] Already pinned"); return
        }
        let m = MirrorPanel(scWindow: scWindow)
        mirrors.append(m)
        Task { await m.start() }
        PinStore.shared.recordPin(m)

        print("[OK] 📌 Pinned: \(m.appName) (wid: \(scWindow.windowID)) total: \(mirrors.count)")
        showHUD(icon: "pin", m.appName)
    }

    private func remove(_ m: MirrorPanel) {
        PinStore.shared.recordUnpin(m)
        m.stop()
    }

    // Unpin a specific window (called when its target app closes)
    func unpinWindow(windowID: CGWindowID) {
        guard let idx = mirrors.firstIndex(where: { $0.scWindow.windowID == windowID }) else { return }
        let m = mirrors.remove(at: idx)
        remove(m)
        print("[OK] 📍 Unpinned: \(m.appName)")
    }

    // Unpin most recently pinned
    func unpinLast() {
        guard let m = mirrors.last else { return }
        mirrors.removeLast()
        remove(m)
        print("[OK] 📍 Unpinned: \(m.appName)")
        showHUD(icon: "pin-off", m.appName)
    }

    func unpinAll() {
        mirrors.forEach { remove($0) }
        mirrors.removeAll()
        print("[OK] 📍 Unpinned all")
        showHUD(icon: "pin-off", "All unpinned")
    }

    private func findFrontmostSCWindow(pid: pid_t) -> SCWindow? {
        // Step 1: Get the frontmost AXUIElement window and extract its CGWindowID
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        var axWindow: AXUIElement?

        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success, let w = ref {
            axWindow = (w as! AXUIElement)
        } else if AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &ref) == .success, let w = ref {
            axWindow = (w as! AXUIElement)
        } else if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
                  let list = ref as? [AXUIElement], let first = list.first {
            axWindow = first
        }

        guard let axWin = axWindow else {
            print("[WARN] Cannot get AX window for pid \(pid)"); return nil
        }

        // Extract CGWindowID via private _AXUIElementGetWindow
        typealias GetWinFn = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError
        let fn: GetWinFn = {
            let h = dlopen(nil, RTLD_NOW)!
            return unsafeBitCast(dlsym(h, "_AXUIElementGetWindow"), to: GetWinFn.self)
        }()
        var windowID: CGWindowID = 0
        guard fn(axWin, &windowID) == .success, windowID != 0 else {
            print("[WARN] Cannot get CGWindowID"); return nil
        }
        print("[DEBUG] Target windowID: \(windowID)")

        // Step 2: Sync-fetch SCShareableContent and find matching window
        let semaphore = DispatchSemaphore(value: 0)
        var result: SCShareableContent?
        // onScreenWindowsOnly:false so we catch all windows including partially hidden
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, err in
            if let err = err { print("[WARN] SCKit error: \(err)") }
            result = content
            semaphore.signal()
        }
        semaphore.wait()

        guard let content = result else {
            print("[WARN] SCKit returned nil content"); return nil
        }

        print("[DEBUG] SCKit windows: \(content.windows.count)")
        let found = content.windows.first(where: { $0.windowID == windowID })
        if found == nil {
            print("[WARN] windowID \(windowID) not in SC list. IDs: \(content.windows.prefix(10).map(\.windowID))")
        }
        return found
    }


    func showHUD(icon: String, _ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 18, weight: .medium)
        label.textColor = .white

        let stack = NSStackView(views: [label])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        if let img = lucideIcon(icon, size: 22) {
            let iv = NSImageView(image: img)
            iv.contentTintColor = .white
            stack.insertArrangedSubview(iv, at: 0)
        }
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize

        let w = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.level = .screenSaver
        w.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        w.isOpaque = false
        w.hasShadow = true
        w.center()
        w.contentView?.wantsLayer = true
        w.contentView?.layer?.cornerRadius = 12
        stack.frame = w.contentView!.bounds
        w.contentView?.addSubview(stack)
        w.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { w.close() }
    }
}

// MARK: - Hotkey Handler

private var hotKeyRefs: [EventHotKeyRef?] = []

private func installHotkeys() {
    let keys: [(UInt32, UInt32, UInt32)] = [
        (0x23, UInt32(optionKey), 1),   // Option+P = pin
        (0x20, UInt32(optionKey), 2),   // Option+U = unpin
    ]
    var sig: OSType = 0
    for c in "WPIN".utf8 { sig = (sig << 8) | OSType(c) }

    for (keyCode, modifiers, hotID) in keys {
        let hkID = EventHotKeyID(signature: sig, id: hotID)
        var ref: EventHotKeyRef?
        let s = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        print("[DEBUG] RegisterHotKey 0x\(String(keyCode, radix: 16)) -> \(s == 0 ? "OK" : "FAIL(\(s))")")
        hotKeyRefs.append(ref)
    }

    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
        var hkID = EventHotKeyID()
        GetEventParameter(event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID),
                          nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
        DispatchQueue.main.async {
            if hkID.id == 1 { WindowPinManager.shared.pinFrontmost() }
            else { WindowPinManager.shared.unpinLast() }
        }
        return noErr
    }, 1, &spec, nil, nil)
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ n: Notification) {
        // Check silently first; only prompt for permissions not yet granted
        var axTrusted = AXIsProcessTrusted()
        if !axTrusted {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            axTrusted = AXIsProcessTrustedWithOptions(opts)
        }
        print("[DEBUG] Accessibility: \(axTrusted)")

        var scGranted = CGPreflightScreenCaptureAccess()
        if !scGranted { scGranted = CGRequestScreenCaptureAccess() }
        print("[DEBUG] Screen Recording: \(scGranted)")

        setupMenuBar()
        installHotkeys()

        // Mirror is click-through only while its own app is active
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notif in
            guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            WindowPinManager.shared.mirrors.forEach { $0.setPassThrough($0.targetPID == app.processIdentifier) }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { notif in
            if let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                // Auto-unpin any mirrors whose target app just closed
                let toRemove = WindowPinManager.shared.mirrors.filter {
                    $0.scWindow.owningApplication?.bundleIdentifier == app.bundleIdentifier
                }
                toRemove.forEach { WindowPinManager.shared.unpinWindow(windowID: $0.scWindow.windowID) }
            }
        }
        print("[OK] WindowPin started. ⌥P = pin, ⌥U = unpin.")
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let img = lucideIcon("pin", size: 15) {
            statusItem?.button?.image = img   // template: tints for light/dark menu bar
        } else {
            statusItem?.button?.title = "📌"
        }
        let menu = NSMenu()
        for (title, sel) in [("⌥P  Pin frontmost window", #selector(pinFromMenu)),
                             ("⌥U  Unpin", #selector(unpinFromMenu))] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())
        let pins = NSMenuItem(title: "Show Pins…", action: #selector(showPins), keyEquivalent: "")
        pins.target = self
        menu.addItem(pins)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit WindowPin", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    // Menu click makes WindowPin frontmost; wait for menu to close and focus to return
    @objc func pinFromMenu() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { WindowPinManager.shared.pinFrontmost() }
    }
    @objc func unpinFromMenu() { WindowPinManager.shared.unpinLast() }
    @objc func showPins() { PinsWindow.shared.show() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(unpinFromMenu) { return !WindowPinManager.shared.mirrors.isEmpty }
        return true
    }
}
