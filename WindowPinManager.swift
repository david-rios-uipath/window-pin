import Cocoa
import ScreenCaptureKit

class WindowPinManager {
    static let shared = WindowPinManager()
    var mirrors: [MirrorPanel] = []

    // ⌥P toggles: pin the frontmost window, or unpin it if already pinned
    @MainActor
    func togglePinFrontmost() async {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            print("[WARN] No frontmost app"); return
        }
        guard let scWindow = await findFrontmostSCWindow(pid: frontApp.processIdentifier) else {
            print("[WARN] Cannot find SC window"); return
        }
        if mirrors.contains(where: { $0.scWindow.windowID == scWindow.windowID }) {
            unpinWindow(windowID: scWindow.windowID)
        } else {
            pin(scWindow)
        }
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

    func unpinWindow(windowID: CGWindowID) {
        guard let idx = mirrors.firstIndex(where: { $0.scWindow.windowID == windowID }) else { return }
        let m = mirrors.remove(at: idx)
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

    private func findFrontmostSCWindow(pid: pid_t) async -> SCWindow? {
        guard let axWin = AXUIElement.frontWindow(pid: pid) else {
            print("[WARN] Cannot get AX window for pid \(pid)"); return nil
        }
        guard let windowID = axWin.windowID else {
            print("[WARN] Cannot get CGWindowID"); return nil
        }
        print("[DEBUG] Target windowID: \(windowID)")

        // onScreenWindowsOnly:false so we catch all windows including partially hidden
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            print("[WARN] SCKit error: \(error)"); return nil
        }

        print("[DEBUG] SCKit windows: \(content.windows.count)")
        let found = content.windows.first(where: { $0.windowID == windowID })
        if found == nil {
            print("[WARN] windowID \(windowID) not in SC list. IDs: \(content.windows.prefix(10).map(\.windowID))")
        }
        return found
    }
}
