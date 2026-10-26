import Cocoa

setvbuf(stdout, nil, _IOLBF, 0)   // line-buffer so logs show when piped to a file
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
