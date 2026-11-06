import AppKit
import Foundation

@_cdecl("rex_agent_start")
public func rexAgentStart() {
    Task { @MainActor in AgentPaneHost.shared.start() }
}

@_cdecl("rex_agent_snapshot")
public func rexAgentSnapshot() {
    Task { @MainActor in AgentPaneHost.shared.saveSnapshot() }
}

private struct RexLeaf {
    let id: String
    let rect: CGRect
}

private struct RexPaneSnapshot {
    let sessionID: String
    let zoomedID: String?
    let leaves: [RexLeaf]
    let labels: [String: String]
}

@MainActor
final class AgentPaneHost: NSObject, NSMenuItemValidation {
    static let shared = AgentPaneHost()
    private let root = ProcessInfo.processInfo.environment["REX_AGENT_ROOT"] ?? ""
    private let cli = ProcessInfo.processInfo.environment["REX_AGENT_CLI"] ?? "/usr/local/bin/rex"
    private weak var nativeWindow: NSWindow?
    private var sessionLabels: [String: String] = [:]
    private var snapshots: [String: RexPaneSnapshot] = [:]
    private var fetching: Set<String> = []
    private var lastSessionRefresh: [String: Date] = [:]
    private var primaryWindowNumbers: [String: Int] = [:]
    private var fetchingDirectory = false
    private var lastDirectoryRefresh = Date.distantPast
    private var clientID: String?
    private var fetchingClient = false
    private var overlays: [ObjectIdentifier: (view: NSView, block: String)] = [:]
    private var viewsByBlock: [String: (sessionID: String, view: NSView)] = [:]
    private var preparingViews: Set<String> = []
    private var timer: Timer?
    private var menu: NSMenuItem?
    private var monitor: Any?
    private var logged = false

    func start() {
        guard timer == nil else { return }
        log("Native agent pane loaded in \(Bundle.main.bundlePath)")
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.intersection([.command, .shift, .control, .option]) == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "a" {
                let handled = MainActor.assumeIsolated {
                    event.isARepeat ? self.canCreateAgentPane(in: event.window ?? NSApp.keyWindow)
                        : self.newAgentPane(in: event.window ?? NSApp.keyWindow)
                }
                return handled ? nil : event
            }
            return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            Task { @MainActor in
                self.installMenu()
                self.refresh()
                self.attach()
            }
        }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installMenu() {
        guard let main = NSApp.mainMenu, menu?.menu !== main else { return }
        if let menu { menu.menu?.removeItem(menu) }
        let top = NSMenuItem(title: "Agent", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Agent")
        let item = NSMenuItem(title: "New Agent Pane", action: #selector(newAgentPaneFromMenu(_:)), keyEquivalent: "a")
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = self
        submenu.addItem(item)
        submenu.addItem(.separator())
        let appearance = NSMenuItem(title: "Appearance…", action: #selector(showAgentAppearance(_:)), keyEquivalent: "")
        appearance.target = self
        submenu.addItem(appearance)
        top.submenu = submenu
        main.addItem(top)
        menu = top
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(showAgentAppearance(_:)) || canCreateAgentPane(in: NSApp.keyWindow)
    }

    @objc private func showAgentAppearance(_ sender: NSMenuItem) {
        AgentAppearance.shared.showPreferences()
    }

    private func sessionID(in window: NSWindow) -> String? {
        guard window.isVisible, window.styleMask.contains(.titled), !(window is NSPanel) else { return nil }
        let matches = sessionLabels.filter { window.title.hasSuffix(" - \($0.value)") }
        let longest = matches.values.map(\.count).max()
        let candidates = matches.filter { $0.value.count == longest }
        return candidates.count == 1 ? candidates.keys.first : nil
    }

    private func canCreateAgentPane(in window: NSWindow?) -> Bool {
        guard clientID != nil, let window, NSApp.keyWindow === window else { return false }
        return sessionID(in: window) != nil
    }

    @objc private func newAgentPaneFromMenu(_ sender: NSMenuItem) {
        _ = newAgentPane(in: NSApp.keyWindow)
    }

    private func newAgentPane(in window: NSWindow?) -> Bool {
        guard canCreateAgentPane(in: window), let clientID, let window, let session = sessionID(in: window) else {
            log("New pane request rejected: no active Rex session; window=\(window?.title ?? "none")")
            refresh()
            return false
        }
        // Resolve the current window's session, then let Rex resolve its focused
        // block when the action runs. The palette invokes this same action.
        run(["-C", clientID, "do", "rex_agent_new_pane", "-s", session, "app_client_id=\(clientID)"]) { result in
            if case .failure(let error) = result {
                self.log("New pane failed: \(error)")
                self.clientID = nil
            }
            self.refresh()
        }
        return true
    }

    private func refreshDirectory() {
        let unresolved = NSApp.windows.contains { $0.isVisible && !($0 is NSPanel) && $0.title.contains(" - ") && sessionID(in: $0) == nil }
        guard !fetchingDirectory, Date().timeIntervalSince(lastDirectoryRefresh) >= (unresolved ? 0.5 : 5) else { return }
        fetchingDirectory = true
        lastDirectoryRefresh = Date()
        run(["ls", "--json"]) { result in
            self.fetchingDirectory = false
            guard case .success(let data) = result,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessions = object["sessions"] as? [[String: Any]] else { return }
            self.sessionLabels = Dictionary(sessions.compactMap { value -> (String, String)? in
                guard let id = value["session_id"] as? String, let label = value["label"] as? String, !label.isEmpty else { return nil }
                return (id, label)
            }, uniquingKeysWith: { _, latest in latest })
            self.snapshots = self.snapshots.filter { self.sessionLabels[$0.key] != nil }
            self.lastSessionRefresh = self.lastSessionRefresh.filter { self.sessionLabels[$0.key] != nil }
            for (id, cached) in self.viewsByBlock where self.sessionLabels[cached.sessionID] == nil {
                cached.view.removeFromSuperview()
                self.viewsByBlock.removeValue(forKey: id)
            }
            self.refresh()
        }
    }

    private func refreshClient() {
        guard clientID == nil, !fetchingClient else { return }
        fetchingClient = true
        run(["client", "ls", "--json"]) { result in
            self.fetchingClient = false
            guard case .success(let data) = result,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let clients = object["clients"] as? [[String: Any]] else { return }
            self.clientID = clients.first { value in
                let info = value["info"] as? [String: Any]
                let principal = value["principal"] as? [String: Any]
                return info?["kind"] as? String == "app" && principal?["pid"] as? Int == Int(getpid()) && value["connection_state"] as? String == "connected"
            }?["client_id"] as? String
        }
    }

    private func visibleSessionWindows() -> [String: NSWindow] {
        var selected: [String: NSWindow] = [:]
        for window in NSApp.windows {
            guard let session = sessionID(in: window) else { continue }
            if selected[session] == nil || window === NSApp.keyWindow ||
                (selected[session] !== NSApp.keyWindow && primaryWindowNumbers[session] == window.windowNumber) {
                selected[session] = window
            }
        }
        // One provider/view owns each block. If two native windows show it,
        // prefer the key window and keep that host stable until focus changes.
        primaryWindowNumbers = selected.mapValues(\.windowNumber)
        return selected
    }

    private func refresh() {
        refreshDirectory()
        refreshClient()
        let visible = Set(visibleSessionWindows().keys)
        for id in visible { refreshSession(id) }
        let cached = Set(viewsByBlock.values.map(\.sessionID))
        for id in cached.subtracting(visible) where Date().timeIntervalSince(lastSessionRefresh[id] ?? .distantPast) >= 10 {
            refreshSession(id)
        }
    }

    private func refreshSession(_ session: String) {
        guard !fetching.contains(session) else { return }
        fetching.insert(session)
        lastSessionRefresh[session] = Date()
        run(["session", "inspect", session, "--json"]) { result in
            self.fetching.remove(session)
            guard case .success(let data) = result,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let windows = object["windows"] as? [[String: Any]] else { return }
            let existingBlocks = Set(windows.flatMap { $0["layers"] as? [[String: Any]] ?? [] }.flatMap { $0["blocks"] as? [[String: Any]] ?? [] }.compactMap { $0["block_id"] as? String })
            for (id, cached) in self.viewsByBlock where cached.sessionID == session && !existingBlocks.contains(id) {
                cached.view.removeFromSuperview()
                self.viewsByBlock.removeValue(forKey: id)
            }
            guard let active = object["active_window_id"] as? String,
                  let window = windows.first(where: { $0["window_id"] as? String == active }),
                  let layers = window["layers"] as? [[String: Any]] else {
                self.snapshots.removeValue(forKey: session)
                self.attach()
                return
            }
            var leaves: [RexLeaf] = []
            var labels: [String: String] = [:]
            func walk(_ node: [String: Any]) {
                if let id = node["block_id"] as? String, let r = node["rect"] as? [Double], r.count == 4 {
                    leaves.append(RexLeaf(id: id, rect: CGRect(x: r[0], y: r[1], width: r[2], height: r[3])))
                }
                for key in ["before", "after"] { if let child = node[key] as? [String: Any] { walk(child) } }
                if let split = node["split"] as? [String: Any] { walk(split) }
                if let children = node["children"] as? [[String: Any]] { children.forEach(walk) }
            }
            for layer in layers where layer["kind"] as? String == "tiled" {
                if let layout = layer["layout"] as? [String: Any] { walk(layout) }
                for block in layer["blocks"] as? [[String: Any]] ?? [] {
                    if let id = block["block_id"] as? String { labels[id] = block["label"] as? String ?? "" }
                }
            }
            let zoomed = window["zoomed_block_id"] as? String
            if let zoomed, leaves.contains(where: { $0.id == zoomed }) {
                leaves = [RexLeaf(id: zoomed, rect: CGRect(x: 0, y: 0, width: 1, height: 1))]
            }
            self.snapshots[session] = RexPaneSnapshot(sessionID: session, zoomedID: zoomed, leaves: leaves, labels: labels)
            self.attach()
        }
    }

    private func attach() {
        var alive = Set<ObjectIdentifier>()
        for (session, window) in visibleSessionWindows() {
            guard let rootView = window.contentView, let snapshot = snapshots[session] else { continue }
            if nativeWindow == nil || window === NSApp.keyWindow { nativeWindow = window }
            var surfaces: [NSView] = []
            func visit(_ view: NSView) {
                let name = NSStringFromClass(type(of: view))
                if name == "GhosttyTerminal.SurfaceView" || name == "_TtC15GhosttyTerminal11SurfaceView" {
                    if !view.isHiddenOrHasHiddenAncestor && !view.visibleRect.isEmpty { surfaces.append(view) }
                    return
                }
                if String(describing: type(of: view)) == "AgentPaneView" { return }
                view.subviews.forEach(visit)
            }
            visit(rootView)
            // Rex retains the other terminal surfaces underneath its zoomed pane.
            // The server explicitly names the zoomed block; its surface alone
            // expands to the full workspace while the others keep their old size.
            if snapshot.zoomedID != nil, surfaces.count > 1 {
                let largest = surfaces.sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }
                guard largest[0].bounds.width * largest[0].bounds.height > largest[1].bounds.width * largest[1].bounds.height else { continue }
                surfaces = [largest[0]]
            }
            if !logged && !surfaces.isEmpty {
                logged = true
                dumpViews(rootView)
            }
            let boxes = surfaces.map { $0.convert($0.bounds, to: rootView) }
            let union = boxes.reduce(CGRect.null) { $0.union($1) }
            guard union.width > 0, union.height > 0, surfaces.count == snapshot.leaves.count else { continue }
            for (surface, box) in zip(surfaces, boxes) {
                let center = CGPoint(x: (box.midX - union.minX) / union.width,
                                     y: rootView.isFlipped ? (box.midY - union.minY) / union.height : (union.maxY - box.midY) / union.height)
                guard let leaf = snapshot.leaves.first(where: { $0.rect.contains(center) }),
                      snapshot.labels[leaf.id]?.hasPrefix("rex-agent:") == true else { continue }
                // Rex's native pane title/controls sit above this host. Mount only
                // in the terminal body so split, drag and close remain native.
                guard let container = surface.superview else { continue }
                let key = ObjectIdentifier(container)
                alive.insert(key)
                if let existing = overlays[key], existing.block != leaf.id {
                    existing.view.removeFromSuperview()
                    overlays.removeValue(forKey: key)
                }
                if overlays[key] == nil {
                    guard let cached = viewsByBlock[leaf.id] else {
                        prepareView(block: leaf.id, session: snapshot.sessionID)
                        continue
                    }
                    let view = cached.view
                    for (oldKey, old) in overlays where oldKey != key && old.view === view {
                        overlays.removeValue(forKey: oldKey)
                    }
                    view.frame = surface.frame
                    view.autoresizingMask = [.width, .height]
                    container.addSubview(view, positioned: .above, relativeTo: nil)
                    overlays[key] = (view, leaf.id)
                    log("Attached native view block=\(leaf.id) container=\(type(of: container)) frame=\(view.frame)")
                } else if let view = overlays[key]?.view {
                    view.frame = surface.frame
                    if view.superview !== container { container.addSubview(view, positioned: .above, relativeTo: nil) }
                }
            }
        }
        for (key, overlay) in overlays where !alive.contains(key) {
            overlay.view.removeFromSuperview()
            overlays.removeValue(forKey: key)
        }
    }

    private func prepareView(block: String, session: String) {
        guard !preparingViews.contains(block) else { return }
        preparingViews.insert(block)
        run(["block", "call", "-s", session, "-b", block, "process"]) { result in
            self.preparingViews.remove(block)
            guard self.snapshots[session]?.labels[block]?.hasPrefix("rex-agent:") == true else { return }
            guard case .success(let data) = result,
                  let process = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let foreground = process["foreground"] as? [String: Any]
            let child = process["child"] as? [String: Any]
            // A just-created process may not have a cwd yet. Retry on the next
            // attachment pass rather than start its agent in another project.
            guard let cwd = [foreground?["cwd"] as? String, child?["cwd"] as? String].compactMap({ $0 }).first(where: { !$0.isEmpty }) else { return }
            let view: NSView
            #if PROBE
            let label = NSTextField(labelWithString: "Native Rex Agent pane\n\(block)")
            label.font = .systemFont(ofSize: 24)
            label.textColor = .labelColor
            view = NSView(frame: .zero)
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            label.frame = CGRect(x: 24, y: 24, width: 500, height: 100)
            view.addSubview(label)
            #else
            view = AgentPaneView(projectRoot: self.root, sessionID: session, blockID: block, cwd: cwd)
            #endif
            self.viewsByBlock[block] = (session, view)
            self.attach()
        }
    }

    func saveSnapshot() {
        for window in NSApp.windows where window.styleMask.contains(.titled) && !(window is NSPanel) {
            log("Window title=\(window.title) visible=\(window.isVisible) identifier=\(window.identifier?.rawValue ?? "")")
            if let content = window.contentView { dumpViews(content) }
        }
        if let content = nativeWindow?.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: root + "/build/native-workspace.png"))
            }
        }
        guard let view = overlays.values.first?.view,
              let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            log("Snapshot requested with no mounted agent pane")
            return
        }
        view.cacheDisplay(in: view.bounds, to: image)
        if let png = image.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: root + "/build/native-pane.png"))
            log("Native pane snapshot saved")
        }
    }

    private func run(_ arguments: [String], completion: @escaping @MainActor (Result<Data, Error>) -> Void) {
        let executable = cli
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "REX_SESSION")
            environment.removeValue(forKey: "REX_BLOCK")
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus != 0 { throw NSError(domain: "RexAgent", code: Int(process.terminationStatus)) }
                Task { @MainActor in completion(.success(data)) }
            } catch { Task { @MainActor in completion(.failure(error)) } }
        }
    }

    private func log(_ line: String) {
        guard !root.isEmpty else { return }
        let url = URL(fileURLWithPath: root).appendingPathComponent("build/native.log")
        let data = Data(("\(Date()) \(line)\n").utf8)
        if let file = try? FileHandle(forWritingTo: url) {
            file.seekToEndOfFile(); file.write(data); try? file.close()
        } else { try? data.write(to: url) }
    }

    private func dumpViews(_ rootView: NSView) {
        var lines: [String] = []
        func visit(_ view: NSView, depth: Int) {
            lines.append("\(String(repeating: "  ", count: depth))\(NSStringFromClass(type(of: view))) frame=\(view.frame) visible=\(view.visibleRect) hidden=\(view.isHiddenOrHasHiddenAncestor) id=\(view.identifier?.rawValue ?? "") ax=\(view.accessibilityIdentifier())")
            if depth < 18 { view.subviews.forEach { visit($0, depth: depth + 1) } }
        }
        visit(rootView, depth: 0)
        try? lines.joined(separator: "\n").write(toFile: root + "/build/views.txt", atomically: true, encoding: .utf8)
    }
}
