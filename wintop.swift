import Cocoa
import Carbon
import ScreenCaptureKit
import AVFoundation

// MARK: - Screen Capture Manager (from Topit)

class CaptureManager: NSObject, SCStreamDelegate, SCStreamOutput {
    let videoLayer = AVSampleBufferDisplayLayer()
    var staticLayer: CALayer?      // fallback: holds last rendered frame
    private var stream: SCStream?
    var capturing = false
    var onError: (() -> Void)?

    func startCapture(window: SCWindow) async throws {
        if stream != nil { return }
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.capturesAudio = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)

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
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.capturesAudio = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.width  = width
        config.height = height
        s.updateConfiguration(config) { err in
            if let err = err { print("[WARN] updateConfig: \(err)") }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid, outputType == .screen else { return }
        DispatchQueue.main.async {
            self.videoLayer.enqueue(sampleBuffer)
            // Update static fallback layer so there's always a last-known-good frame
            if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
               let sl = self.staticLayer {
                let ciImage = CIImage(cvPixelBuffer: imageBuffer)
                let context = CIContext()
                if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    sl.contents = cgImage
                    CATransaction.commit()
                }
            }
        }
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

// MARK: - Coordinate Transform

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
    private var aliveTimer: Timer?    // low-freq timer just to detect window closed

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
        // All mouse events pass through to the real window underneath
        panel.ignoresMouseEvents = true

        let view = NSView(frame: NSRect(origin: .zero, size: nsFrame.size))
        view.wantsLayer = true
        // Clip to corner radius so no black bleed outside rounded corners
        view.layer?.cornerRadius = 10
        view.layer?.masksToBounds = true

        // Static fallback layer — clear background, holds last good frame
        let staticLayer = CALayer()
        staticLayer.frame = view.bounds
        staticLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        staticLayer.backgroundColor = NSColor.clear.cgColor
        view.layer?.addSublayer(staticLayer)
        capture.staticLayer = staticLayer

        // Live video layer on top
        let videoLayer = capture.videoLayer
        videoLayer.frame = view.bounds
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(videoLayer)

        panel.contentView = view

        capture.onError = { [weak self] in
            guard let self = self else { return }
            self.stop()
            WinTopManager.shared.unpinWindow(windowID: self.scWindow.windowID)
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
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], scWindow.windowID) as? [[String: Any]],
              let first = info.first,
              let bounds = first[kCGWindowBounds as String] as? [String: CGFloat] else { return }

        let cgFrame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                             width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        let nsFrame = cgToNS(cgFrame)

        if panel.frame.size != nsFrame.size {
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            capture.updateCaptureSize(width: Int(nsFrame.width * scale), height: Int(nsFrame.height * scale))
        }
        if panel.frame != nsFrame {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            panel.setFrame(nsFrame, display: true)
            CATransaction.commit()
        }
    }

    // Low-frequency check just to detect window closed
    private func checkAlive() {
        let exists = CGWindowListCopyWindowInfo([.optionIncludingWindow], scWindow.windowID) as? [[String: Any]]
        if exists?.isEmpty ?? true {
            WinTopManager.shared.unpinWindow(windowID: scWindow.windowID)
        }
    }

    private func activateRealWindow() {
        if let bundleID = scWindow.owningApplication?.bundleIdentifier,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate()
        }
    }
}

class ClickView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - Window Manager

class WinTopManager {
    static let shared = WinTopManager()
    var mirrors: [MirrorPanel] = []

    func pinFrontmost() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            print("[WARN] No frontmost app"); return
        }

        guard let scWindow = findFrontmostSCWindow(pid: frontApp.processIdentifier) else {
            print("[WARN] Cannot find SC window"); return
        }

        // Don't pin the same window twice
        if mirrors.contains(where: { $0.scWindow.windowID == scWindow.windowID }) {
            print("[WARN] Already pinned"); return
        }

        let m = MirrorPanel(scWindow: scWindow)
        mirrors.append(m)
        Task { await m.start() }

        let name = scWindow.owningApplication?.applicationName ?? "?"
        print("[OK] 📌 Pinned: \(name) (wid: \(scWindow.windowID)) total: \(mirrors.count)")
        showHUD("📌 \(name)")
    }

    // Unpin a specific window (called when its target app closes)
    func unpinWindow(windowID: CGWindowID) {
        guard let idx = mirrors.firstIndex(where: { $0.scWindow.windowID == windowID }) else { return }
        let m = mirrors.remove(at: idx)
        let name = m.scWindow.owningApplication?.applicationName ?? "?"
        m.stop()
        print("[OK] 📍 Auto-unpinned: \(name)")
    }

    // Unpin most recently pinned
    func unpinLast() {
        guard let m = mirrors.last else { return }
        let name = m.scWindow.owningApplication?.applicationName ?? "?"
        mirrors.removeLast()
        m.stop()
        print("[OK] 📍 Unpinned: \(name)")
        showHUD("📍 \(name)")
    }

    func unpinAll() {
        mirrors.forEach { $0.stop() }
        mirrors.removeAll()
        print("[OK] 📍 Unpinned all")
        showHUD("📍 All unpinned")
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


    private func showHUD(_ text: String) {
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 50),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.level = .screenSaver
        w.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        w.isOpaque = false
        w.hasShadow = true
        w.center()
        w.contentView?.wantsLayer = true
        w.contentView?.layer?.cornerRadius = 12

        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 18, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.frame = w.contentView!.bounds
        label.autoresizingMask = [.width, .height]
        w.contentView?.addSubview(label)
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
    for c in "WTOP".utf8 { sig = (sig << 8) | OSType(c) }

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
            if hkID.id == 1 { WinTopManager.shared.pinFrontmost() }
            else { WinTopManager.shared.unpinLast() }
        }
        return noErr
    }, 1, &spec, nil, nil)
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ n: Notification) {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        print("[DEBUG] Accessibility: \(trusted)")

        setupMenuBar()
        installHotkeys()

        // Proactively request ScreenCaptureKit permission on launch
        // This triggers the TCC dialog if not yet granted
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, err in
            if let err = err {
                print("[DEBUG] SC permission check: \(err.localizedDescription)")
            } else {
                print("[DEBUG] SC permission: granted, \(content?.windows.count ?? 0) windows available")
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { notif in
            if let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                // Auto-unpin any mirrors whose target app just closed
                let toRemove = WinTopManager.shared.mirrors.filter {
                    $0.scWindow.owningApplication?.bundleIdentifier == app.bundleIdentifier
                }
                toRemove.forEach { WinTopManager.shared.unpinWindow(windowID: $0.scWindow.windowID) }
            }
        }
        print("[OK] WinTop started. ⌥P = pin, ⌥U = unpin.")
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.title = "📌"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "⌥P  Pin frontmost window", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "⌥U  Unpin", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit WinTop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }
}

// MARK: - Main
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
