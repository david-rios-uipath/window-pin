import Cocoa
import SwiftUI
import ScreenCaptureKit

// MARK: - Records + persistence

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

// Recents live at ~/Library/Application Support/WindowPin/{recent.json, thumbs/<id>.png}
final class PinStore {
    static let shared = PinStore()
    static let recentCap = 8

    private(set) var records: [PinRecord] = []
    private var thumbs: [CGWindowID: NSImage] = [:]
    private let dir: URL
    private var jsonURL: URL { dir.appendingPathComponent("recent.json") }
    private func pngURL(_ id: CGWindowID) -> URL { dir.appendingPathComponent("thumbs/\(id).png") }

    private init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WindowPin")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("thumbs"), withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: jsonURL), let r = try? JSONDecoder().decode([PinRecord].self, from: data) {
            records = r
        }
    }

    func recordPin(_ m: MirrorPanel) {
        records.removeAll { $0.windowID == m.scWindow.windowID }
        records.insert(PinRecord(windowID: m.scWindow.windowID, title: m.liveTitle, appName: m.appName,
                                 bundleID: m.bundleID, pid: m.targetPID ?? 0, lastPinned: Date(), lastUnpinned: nil), at: 0)
        persist()
        Task { await refreshThumbnail(m) }
    }

    func recordUnpin(_ m: MirrorPanel) {
        guard let i = records.firstIndex(where: { $0.windowID == m.scWindow.windowID }) else { return }
        records[i].title = m.liveTitle
        records[i].lastUnpinned = Date()
        if let img = thumbs[m.scWindow.windowID], let png = img.pngData { try? png.write(to: pngURL(m.scWindow.windowID)) }
        trim()
        persist()
    }

    func drop(_ ids: [CGWindowID]) {
        guard !ids.isEmpty else { return }
        records.removeAll { ids.contains($0.windowID) }
        ids.forEach { thumbs[$0] = nil; try? FileManager.default.removeItem(at: pngURL($0)) }
        persist()
    }

    func thumbnail(for id: CGWindowID) -> NSImage? {
        if let t = thumbs[id] { return t }
        let t = NSImage(contentsOf: pngURL(id))
        thumbs[id] = t
        return t
    }

    // One small GPU-side capture; no per-frame work
    func refreshThumbnail(_ m: MirrorPanel) async {
        let filter = SCContentFilter(desktopIndependentWindow: m.scWindow)
        let cfg = SCStreamConfiguration()
        let r = filter.contentRect
        cfg.width = 320
        cfg.height = max(1, Int(320 * r.height / max(r.width, 1)))
        cfg.showsCursor = false
        cfg.scalesToFit = true
        guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) else { return }
        await MainActor.run { thumbs[m.scWindow.windowID] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
    }

    private func trim() {
        let unpinned = records.filter { $0.lastUnpinned != nil }.sorted { $0.lastUnpinned! > $1.lastUnpinned! }
        drop(unpinned.dropFirst(Self.recentCap).map(\.windowID))
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: jsonURL) }
    }
}

extension NSImage {
    var pngData: Data? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}

// MARK: - View model

struct PinItem: Identifiable {
    let id: CGWindowID
    let title: String
    let appName: String
    let icon: NSImage?
    let thumb: NSImage?
    let scWindow: SCWindow?   // set for recents that can be re-pinned
}

@MainActor
final class PinsModel: ObservableObject {
    @Published var pinned: [PinItem] = []
    @Published var recent: [PinItem] = []
    private var timer: Timer?

    func start() {
        reload()
        Task { await refreshAll() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { await self?.refreshAll() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }

    // Re-capture pinned thumbnails and re-check which recents still exist
    private func refreshAll() async {
        let mirrors = WindowPinManager.shared.mirrors
        for m in mirrors { await PinStore.shared.refreshThumbnail(m) }
        let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let live = Dictionary(uniqueKeysWithValues: (content?.windows ?? []).map { ($0.windowID, $0) })
        // Recents whose window is gone (or whose id was reused by another process) are dropped for good
        let pinnedIDs = Set(mirrors.map(\.scWindow.windowID))
        let dead = PinStore.shared.records.filter { r in
            !pinnedIDs.contains(r.windowID) && live[r.windowID]?.owningApplication.map { pid_t($0.processID) } != r.pid
        }.map(\.windowID)
        PinStore.shared.drop(dead)
        reload(live: live)
    }

    func reload(live: [CGWindowID: SCWindow] = [:]) {
        let mirrors = WindowPinManager.shared.mirrors
        pinned = mirrors.map {
            PinItem(id: $0.scWindow.windowID, title: $0.liveTitle, appName: $0.appName,
                    icon: Self.icon(pid: $0.targetPID, bundleID: $0.bundleID),
                    thumb: PinStore.shared.thumbnail(for: $0.scWindow.windowID), scWindow: nil)
        }
        let pinnedIDs = Set(pinned.map(\.id))
        recent = PinStore.shared.records
            .filter { !pinnedIDs.contains($0.windowID) && $0.lastUnpinned != nil }
            .sorted { $0.lastUnpinned! > $1.lastUnpinned! }
            .map { PinItem(id: $0.windowID, title: $0.title, appName: $0.appName,
                           icon: Self.icon(pid: $0.pid, bundleID: $0.bundleID),
                           thumb: PinStore.shared.thumbnail(for: $0.windowID), scWindow: live[$0.windowID]) }
    }

    func unpin(_ item: PinItem) { WindowPinManager.shared.unpinWindow(windowID: item.id); reload() }
    func focus(_ item: PinItem) { WindowPinManager.shared.mirrors.first { $0.scWindow.windowID == item.id }?.focusRealWindow() }
    func repin(_ item: PinItem) {
        guard let w = item.scWindow else {
            WindowPinManager.shared.showHUD(icon: "pin-off", "Window no longer exists"); return
        }
        WindowPinManager.shared.pin(w)
        reload()
    }

    private static func icon(pid: pid_t?, bundleID: String?) -> NSImage? {
        if let pid = pid, let app = NSRunningApplication(processIdentifier: pid), let i = app.icon { return i }
        if let b = bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }
}

// MARK: - Views

struct PinsView: View {
    @ObservedObject var model: PinsModel
    private let columns = [GridItem(.adaptive(minimum: 180), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.pinned.isEmpty && model.recent.isEmpty {
                    Text("No pinned windows. Press ⌥P on a window to pin it.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                }
                section("Pinned", model.pinned) { item in
                    PinCard(item: item, primary: ("Bring to front", { model.focus(item) }),
                            secondary: ("Unpin", { model.unpin(item) }))
                }
                section("Recently pinned", model.recent) { item in
                    PinCard(item: item, primary: ("Pin again", { model.repin(item) }), secondary: nil)
                }
            }
            .padding(16)
        }
        .frame(width: 640, height: 480)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [PinItem], @ViewBuilder card: @escaping (PinItem) -> PinCard) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline).foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(items) { card($0) }
                }
            }
        }
    }
}

struct PinCard: View {
    let item: PinItem
    let primary: (String, () -> Void)
    let secondary: (String, () -> Void)?
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor))
                if let t = item.thumb {
                    Image(nsImage: t).resizable().scaledToFit().padding(2)
                } else {
                    Image(systemName: "macwindow").font(.largeTitle).foregroundStyle(.tertiary)
                }
                if hover {
                    HStack(spacing: 8) {
                        Button(primary.0, action: primary.1)
                        if let s = secondary { Button(s.0, action: s.1) }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            .aspectRatio(16/10, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))

            HStack(spacing: 6) {
                if let i = item.icon { Image(nsImage: i).resizable().frame(width: 16, height: 16) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.callout).lineLimit(1).truncationMode(.middle)
                    Text(item.appName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())   // whole card is the hover/click target, including gaps
        .onHover { hover = $0 }
        .onTapGesture(perform: primary.1)
        .contextMenu {
            Button(primary.0, action: primary.1)
            if let s = secondary { Button(s.0, action: s.1) }
        }
    }
}

// MARK: - Window

final class PinsWindow: NSWindow, NSWindowDelegate {
    static let shared = PinsWindow()
    private let model = PinsModel()
    private var previousApp: NSRunningApplication?

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                   styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        title = "Pins"
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)   // above the mirrors
        contentView = NSHostingView(rootView: PinsView(model: model))
        delegate = self
    }

    func show() {
        previousApp = NSWorkspace.shared.frontmostApplication
        model.start()
        center()
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    override func cancelOperation(_ sender: Any?) { close() }   // Esc

    func windowWillClose(_ notification: Notification) {
        model.stop()
        previousApp?.activate()   // restores mirror pass-through for that app
    }
}
