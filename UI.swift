import Cocoa

enum Settings {
    static var showBadge: Bool {
        get { UserDefaults.standard.object(forKey: "showBadge") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "showBadge")
            WindowPinManager.shared.mirrors.forEach { $0.badge.isHidden = !newValue }
        }
    }
}

func lucideIcon(_ name: String, size: CGFloat) -> NSImage? {
    guard let path = Bundle.main.path(forResource: name, ofType: "svg"), let img = NSImage(contentsOfFile: path) else { return nil }
    img.size = NSSize(width: size, height: size)
    img.isTemplate = true
    return img
}

// Centered toast, auto-dismisses after 1s
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
