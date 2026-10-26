import Cocoa
import Carbon

// MARK: - Hotkey Handler

private var hotKeyRefs: [EventHotKeyRef?] = []

private func installHotkeys() {
    let keys: [(UInt32, UInt32, UInt32)] = [
        (0x23, UInt32(optionKey), 1),   // Option+P = pin / unpin
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
        if hkID.id == 1 { Task { @MainActor in await WindowPinManager.shared.togglePinFrontmost() } }
        return noErr
    }, 1, &spec, nil, nil)
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
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

        // Auto-unpin any mirrors whose target app just closed
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { notif in
            guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            WindowPinManager.shared.mirrors
                .filter { $0.bundleID == app.bundleIdentifier }
                .forEach { WindowPinManager.shared.unpinWindow(windowID: $0.scWindow.windowID) }
        }
        print("[OK] WindowPin started. ⌥P = pin / unpin.")
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let img = lucideIcon("pin", size: 15) {
            statusItem?.button?.image = img   // template: tints for light/dark menu bar
        } else {
            statusItem?.button?.title = "📌"
        }
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Pin / unpin frontmost window", action: #selector(pinFromMenu), keyEquivalent: "p")
        toggle.keyEquivalentModifierMask = .option   // renders ⌥P like Quit's ⌘Q; global hotkey is Carbon
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(NSMenuItem.separator())
        let pins = NSMenuItem(title: "Show Pins…", action: #selector(showPins), keyEquivalent: "")
        pins.target = self
        menu.addItem(pins)
        menu.addItem(NSMenuItem.separator())
        let settings = NSMenu()
        let badge = NSMenuItem(title: "Show badge on pinned windows", action: #selector(toggleBadge), keyEquivalent: "")
        badge.target = self
        badge.state = Settings.showBadge ? .on : .off
        settings.addItem(badge)
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = settings
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit WindowPin", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    // Menu click makes WindowPin frontmost; wait for menu to close and focus to return
    @objc func pinFromMenu() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            Task { @MainActor in await WindowPinManager.shared.togglePinFrontmost() }
        }
    }
    @objc func showPins() { PinsWindow.shared.show() }
    @objc func toggleBadge(_ item: NSMenuItem) {
        Settings.showBadge.toggle()
        item.state = Settings.showBadge ? .on : .off
    }
}
