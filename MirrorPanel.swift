import Cocoa
import ScreenCaptureKit

extension NSRect { var area: CGFloat { isNull ? 0 : width * height } }

func cgToNS(_ cgRect: CGRect) -> NSRect {
    guard let main = NSScreen.screens.first else { return cgRect }
    return NSRect(x: cgRect.origin.x,
                  y: main.frame.height - cgRect.origin.y - cgRect.height,
                  width: cgRect.width, height: cgRect.height)
}

class ClickView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

// Floating panel that mirrors one window via SCStream and tracks it through AX notifications
class MirrorPanel {
    let scWindow: SCWindow
    let capture = CaptureManager()
    var panel: NSPanel!
    private var axObserver: AXObserver?
    private var axWin: AXUIElement?
    private var aliveTimer: Timer?    // low-freq timer just to detect window closed
    private var lastScale: CGFloat = 0
    private var resizeDebounce: DispatchWorkItem?
    let badge = NSView()

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

        // Pin badge, top-right; autoresizing mask keeps it anchored through setFrame
        badge.frame = NSRect(x: view.bounds.maxX - 28, y: view.bounds.maxY - 28, width: 20, height: 20)
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        badge.layer?.cornerRadius = 10
        badge.layer?.zPosition = 1   // above the video layer
        badge.autoresizingMask = [.minXMargin, .minYMargin]
        if let img = lucideIcon("pin", size: 12) {
            let iv = NSImageView(image: img)
            iv.contentTintColor = .white
            iv.frame = badge.bounds.insetBy(dx: 4, dy: 4)
            badge.addSubview(iv)
        }
        badge.isHidden = !Settings.showBadge
        view.addSubview(badge)

        panel.contentView = view

        capture.onError = { [weak self] in
            guard let self = self, self.panel.isVisible else { return }   // hidden: checkAlive restarts later
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
        aliveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkAlive()
        }
    }

    func stop() {
        resizeDebounce?.cancel()
        aliveTimer?.invalidate()
        aliveTimer = nil
        if let obs = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        axObserver = nil
        capture.stopCapture()
        panel.close()
    }

    // MARK: - AXObserver

    private func startAXObserver() {
        guard let pid = targetPID else { return }
        guard let axWin = AXUIElement.window(pid: pid, id: scWindow.windowID) else {
            print("[WARN] AXObserver: cannot find window element")
            return
        }
        self.axWin = axWin

        typealias Callback = @convention(c) (AXObserver, AXUIElement, CFString, UnsafeMutableRawPointer?) -> Void
        let cb: Callback = { _, _, _, ptr in
            guard let ptr = ptr else { return }
            let mirror = Unmanaged<MirrorPanel>.fromOpaque(ptr).takeUnretainedValue()
            DispatchQueue.main.async { mirror.syncFrame() }
        }

        var obs: AXObserver?
        guard AXObserverCreate(pid, cb, &obs) == .success, let observer = obs else { return }

        let ptr = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, axWin, kAXWindowMovedNotification as CFString, ptr)
        AXObserverAddNotification(observer, axWin, kAXWindowResizedNotification as CFString, ptr)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = observer
    }

    // Called by AXObserver immediately when window moves or resizes
    func syncFrame() {
        guard let cgFrame = axWin?.frame ?? cgWindowFrame() else { return }
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

    private func cgWindowFrame() -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], scWindow.windowID) as? [[String: Any]],
              let bounds = info.first?[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        return CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
    }

    // Closed = AX element gone. Off the window server but AX alive = hidden tab / ⌘H:
    // hide the mirror and bring it back (restarting capture if needed) when the window returns.
    private func checkAlive() {
        if let w = axWin, !w.isAlive {
            WindowPinManager.shared.unpinWindow(windowID: scWindow.windowID); return
        }
        let onServer = !((CGWindowListCopyWindowInfo([.optionIncludingWindow], scWindow.windowID) as? [[String: Any]])?.isEmpty ?? true)
        if !onServer {
            if axWin == nil { WindowPinManager.shared.unpinWindow(windowID: scWindow.windowID); return }
            if panel.isVisible { panel.orderOut(nil) }
        } else if !panel.isVisible {
            syncFrame()
            panel.orderFront(nil)
            if !capture.capturing { Task { try? await capture.startCapture(window: scWindow) } }
        }
    }

    var targetPID: pid_t? { scWindow.owningApplication.map { pid_t($0.processID) } }
    var appName: String { scWindow.owningApplication?.applicationName ?? "?" }
    var bundleID: String? { scWindow.owningApplication?.bundleIdentifier }

    // AX title is live; SCWindow.title is a snapshot from pin time
    var liveTitle: String {
        if let t: String = axWin?.attr(kAXTitleAttribute), !t.isEmpty { return t }
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
