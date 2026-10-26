import Cocoa

// Private API: CGWindowID for an AX window element
private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError
private let axGetWindow = unsafeBitCast(dlsym(dlopen(nil, RTLD_NOW), "_AXUIElementGetWindow"), to: AXGetWindowFn.self)

extension AXUIElement {
    func attr<T>(_ key: String) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, key as CFString, &ref) == .success else { return nil }
        return ref as? T
    }

    var windowID: CGWindowID? {
        var wid: CGWindowID = 0
        return axGetWindow(self, &wid) == .success && wid != 0 ? wid : nil
    }

    // Position/size straight from the AX element: cheaper than CGWindowList, same coordinate space
    var frame: CGRect? {
        guard let p: AXValue = attr(kAXPositionAttribute), let s: AXValue = attr(kAXSizeAttribute) else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p, .cgPoint, &pos), AXValueGetValue(s, .cgSize, &size) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    // False once the window is closed (element invalidated)
    var isAlive: Bool {
        var ref: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, kAXRoleAttribute as CFString, &ref) != .invalidUIElement
    }

    // Focused, else main, else first window of the app
    static func frontWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        if let w: AXUIElement = app.attr(kAXFocusedWindowAttribute) { return w }
        if let w: AXUIElement = app.attr(kAXMainWindowAttribute) { return w }
        let list: [AXUIElement]? = app.attr(kAXWindowsAttribute)
        return list?.first
    }

    static func window(pid: pid_t, id: CGWindowID) -> AXUIElement? {
        let list: [AXUIElement]? = AXUIElementCreateApplication(pid).attr(kAXWindowsAttribute)
        return list?.first { $0.windowID == id }
    }
}
